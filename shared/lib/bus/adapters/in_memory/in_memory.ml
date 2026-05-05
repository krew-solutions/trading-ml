exception Already_registered_in_group of { uri : string; group : string }

type group_state = { mutable wrapped_callback : (string -> unit) option }
(** Per-group state on a topic. At most one active wrapped callback
    (the [string -> unit] closure that decodes and invokes the typed
    user callback). *)

type topic_state = {
  queue : string Eio.Stream.t;
  groups : (string, group_state) Hashtbl.t;
  mutable dispatcher_started : bool;
}

type broker = {
  sw : Eio.Switch.t;
  topics : (string, topic_state) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let create ~sw = { sw; topics = Hashtbl.create 16; mutex = Eio.Mutex.create () }

let topic_for broker uri =
  Eio.Mutex.use_rw ~protect:true broker.mutex (fun () ->
      match Hashtbl.find_opt broker.topics uri with
      | Some t -> t
      | None ->
          let t =
            {
              queue = Eio.Stream.create 1024;
              groups = Hashtbl.create 4;
              dispatcher_started = false;
            }
          in
          Hashtbl.replace broker.topics uri t;
          t)

let start_dispatcher broker uri topic =
  Eio.Fiber.fork_daemon ~sw:broker.sw (fun () ->
      let rec loop () =
        let payload = Eio.Stream.take topic.queue in
        let groups =
          Eio.Mutex.use_rw ~protect:true broker.mutex (fun () ->
              Hashtbl.fold (fun _ g acc -> g :: acc) topic.groups [])
        in
        List.iter
          (fun (g : group_state) ->
            match g.wrapped_callback with
            | None -> ()
            | Some cb -> (
                try cb payload
                with e ->
                  Logs.warn (fun m ->
                      m "in_memory[%s]: subscriber raised: %s" uri (Printexc.to_string e))
                ))
          groups;
        loop ()
      in
      loop ())

let ensure_dispatcher broker uri topic =
  let needs_start =
    Eio.Mutex.use_rw ~protect:true broker.mutex (fun () ->
        if topic.dispatcher_started then false
        else begin
          topic.dispatcher_started <- true;
          true
        end)
  in
  if needs_start then start_dispatcher broker uri topic

(** Adapter-internal types. Each carries enough state to do its own
    work without re-parameterizing on [broker] — the broker is
    captured in the closures returned by {!adapter}. *)

type 'a consumer_state = {
  c_broker : broker;
  c_uri : string;
  c_group : string;
  c_deserialize : string -> 'a;
}

type 'a producer_state = { p_topic : topic_state; p_serialize : 'a -> string }

type subscription_state = { s_broker : broker; s_topic : topic_state; s_group : string }

let make_consumer broker ~uri ~group ~deserialize =
  let topic = topic_for broker uri in
  Eio.Mutex.use_rw ~protect:true broker.mutex (fun () ->
      if Hashtbl.mem topic.groups group then
        raise (Already_registered_in_group { uri; group })
      else Hashtbl.replace topic.groups group { wrapped_callback = None });
  ensure_dispatcher broker uri topic;
  { c_broker = broker; c_uri = uri; c_group = group; c_deserialize = deserialize }

let make_producer broker ~uri ~serialize =
  let topic = topic_for broker uri in
  ensure_dispatcher broker uri topic;
  { p_topic = topic; p_serialize = serialize }

let do_publish (p : 'a producer_state) value =
  Eio.Stream.add p.p_topic.queue (p.p_serialize value)

let do_subscribe (c : 'a consumer_state) (cb : 'a -> unit) =
  let topic = topic_for c.c_broker c.c_uri in
  let wrapped payload =
    match try Some (c.c_deserialize payload) with _ -> None with
    | Some v -> (
        try cb v
        with e ->
          Logs.warn (fun m ->
              m "in_memory[%s/%s]: callback raised: %s" c.c_uri c.c_group
                (Printexc.to_string e)))
    | None ->
        Logs.warn (fun m -> m "in_memory[%s/%s]: deserialize failed" c.c_uri c.c_group)
  in
  Eio.Mutex.use_rw ~protect:true c.c_broker.mutex (fun () ->
      match Hashtbl.find_opt topic.groups c.c_group with
      | None -> Hashtbl.replace topic.groups c.c_group { wrapped_callback = Some wrapped }
      | Some g -> g.wrapped_callback <- Some wrapped);
  { s_broker = c.c_broker; s_topic = topic; s_group = c.c_group }

let do_unsubscribe (s : subscription_state) =
  Eio.Mutex.use_rw ~protect:true s.s_broker.mutex (fun () ->
      match Hashtbl.find_opt s.s_topic.groups s.s_group with
      | None -> ()
      | Some g -> g.wrapped_callback <- None)

let adapter (broker : broker) : (module Bus.Adapter) =
  (module struct
    type 'a adapter_consumer = 'a consumer_state
    type 'a adapter_producer = 'a producer_state
    type adapter_subscription = subscription_state

    let consumer ~uri ~group ~deserialize = make_consumer broker ~uri ~group ~deserialize

    let producer ~uri ~serialize = make_producer broker ~uri ~serialize
    let publish = do_publish
    let subscribe = do_subscribe
    let unsubscribe = do_unsubscribe
  end)

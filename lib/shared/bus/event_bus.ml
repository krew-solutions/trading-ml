type 'a t = {
  to_string : 'a -> string;
  of_string : string -> 'a;
  stream : string Eio.Stream.t;
  mutable subscribers : (int * ('a -> unit)) list;
  mutable next_id : int;
  mutex : Eio.Mutex.t;
}

type subscription = int

let create (type a) ~sw ~(to_string : a -> string) ~(of_string : string -> a) () : a t =
  let stream = Eio.Stream.create 1024 in
  let t =
    {
      to_string;
      of_string;
      stream;
      subscribers = [];
      next_id = 0;
      mutex = Eio.Mutex.create ();
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        let payload = Eio.Stream.take stream in
        let event =
          try Some (t.of_string payload)
          with e ->
            Logs.warn (fun m ->
                m "event_bus: deserialization failed: %s" (Printexc.to_string e));
            None
        in
        (match event with
        | None -> ()
        | Some ev ->
            let subs = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.subscribers) in
            List.iter
              (fun (_, f) ->
                try f ev
                with e ->
                  Logs.warn (fun m ->
                      m "event_bus: subscriber raised: %s" (Printexc.to_string e)))
              (List.rev subs));
        loop ()
      in
      loop ());
  t

let subscribe t f =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let id = t.next_id in
      t.next_id <- id + 1;
      t.subscribers <- (id, f) :: t.subscribers;
      id)

let unsubscribe t id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.subscribers <- List.filter (fun (i, _) -> i <> id) t.subscribers)

let publish t event = Eio.Stream.add t.stream (t.to_string event)

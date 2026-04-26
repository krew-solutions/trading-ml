(** Finam WebSocket bridge — thin wrapper over {!Websocket.Resilient}.

    One multiplexed socket for all subscriptions. On reconnect,
    resubscribes all active keys. Heartbeat and backoff are handled
    by the resilient layer. *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t
  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)

type bridge = {
  auth : Auth.t;
  on_event : Ws.event -> unit;
  mutex : Eio.Mutex.t;
  mutable conn : Websocket.Resilient.t option;
  mutable bar_subs : Timeframe.t SubMap.t;
  make_conn : on_reconnect:(unit -> unit) -> Websocket.Resilient.t;
}

let make ~env ~sw ~cfg ~auth ~on_event : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        Log.warn "[finam ws] CA load failed: %s" m;
        None
  in
  let t_ref = ref None in
  let make_conn ~on_reconnect =
    let config : Websocket.Resilient.config =
      {
        label = "finam ws";
        ping_interval = 30.0;
        max_backoff = 60.0;
        connect =
          (fun () ->
            Websocket.Client.connect ~env ~sw ~uri:cfg.Config.ws_url ?authenticator ());
        on_text =
          (fun payload ->
            match !t_ref with
            | None -> ()
            | Some t -> (
                try t.on_event (Ws.event_of_json (Yojson.Safe.from_string payload))
                with e ->
                  Log.warn "[finam ws] decode failed: %s raw: %s" (Printexc.to_string e)
                    payload));
        on_reconnect;
      }
    in
    Websocket.Resilient.create ~env ~sw ~config
  in
  let t =
    {
      auth;
      on_event;
      mutex = Eio.Mutex.create ();
      conn = None;
      bar_subs = SubMap.empty;
      make_conn;
    }
  in
  t_ref := Some t;
  t

let send_subscribe t ~instrument ~timeframe =
  let token = Auth.current t.auth in
  let j = Ws.subscribe_message ~token (Sub_bars { instrument; timeframe }) in
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
  | None -> ()

let resubscribe_all t () =
  let subs = Eio.Mutex.use_ro t.mutex (fun () -> t.bar_subs) in
  SubMap.iter
    (fun (instrument, timeframe) _ -> send_subscribe t ~instrument ~timeframe)
    subs

let ensure_conn t =
  match t.conn with
  | Some c -> c
  | None ->
      let c = t.make_conn ~on_reconnect:(resubscribe_all t) in
      t.conn <- Some c;
      c

let subscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      ignore (ensure_conn t);
      t.bar_subs <- SubMap.add (instrument, timeframe) timeframe t.bar_subs);
  send_subscribe t ~instrument ~timeframe

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.unsubscribe_message ~token (Sub_bars { instrument; timeframe }) in
  let should_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.bar_subs <- SubMap.remove (instrument, timeframe) t.bar_subs;
        SubMap.is_empty t.bar_subs)
  in
  match t.conn with
  | Some c ->
      Websocket.Resilient.send c (Yojson.Safe.to_string j);
      if should_close then begin
        Websocket.Resilient.close c;
        t.conn <- None
      end
  | None -> ()

let timeframes_for_instrument (t : bridge) instrument : Timeframe.t list =
  Eio.Mutex.use_ro t.mutex (fun () ->
      SubMap.fold
        (fun (i, tf) _ acc -> if Instrument.equal i instrument then tf :: acc else acc)
        t.bar_subs [])

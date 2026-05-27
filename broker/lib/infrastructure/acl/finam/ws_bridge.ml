(** Finam WebSocket bridge — thin wrapper over {!Websocket.Resilient}.

    One multiplexed socket carries bars + trades. On reconnect,
    the bridge resubscribes all known keys (its own concern); a
    parallel listener registry lets external supervisors react to
    the same WS health transitions — the supervisor pattern for
    the multiplexed-socket case where one disconnect must fan
    across many subscription-level supervisors.

    Listener IDs returned by {!register_lifecycle} are opaque
    integers; callers store them to call {!unregister_lifecycle}
    on tear-down. *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t

  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)
module StringSet = Set.Make (String)
module InstrSet = Set.Make (Instrument)

type listener_id = int

type bridge = {
  auth : Auth.t;
  on_event : Ws.event -> unit;
  mutex : Eio.Mutex.t;
  mutable conn : Websocket.Resilient.t option;
  mutable bar_subs : Timeframe.t SubMap.t;
  mutable trade_subs : StringSet.t;
      (** Account ids currently subscribed for trade-execution
          updates. Tracked so reconnect can re-issue subscribe
          messages for every previously-active account. *)
  mutable public_trade_subs : InstrSet.t;
      (** Instruments currently subscribed for the public tape
          (INSTRUMENT_TRADES). Re-issued on reconnect. *)
  mutable next_listener_id : listener_id;
  mutable disconnect_listeners : (listener_id * (unit -> unit)) list;
  mutable reconnect_listeners : (listener_id * (unit -> unit)) list;
  make_conn : unit -> Websocket.Resilient.t;
}

let fire_listeners (listeners : (listener_id * (unit -> unit)) list) : unit =
  List.iter
    (fun (_, f) ->
      try f ()
      with e -> Log.warn "[finam ws] listener raised: %s" (Printexc.to_string e))
    listeners

let make ~env ~sw ~cfg ~auth ~on_event : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        Log.warn "[finam ws] CA load failed: %s" m;
        None
  in
  let t_ref = ref None in
  let resubscribe_all (t : bridge) () =
    let bar_subs, trade_subs, public_trade_subs =
      Eio.Mutex.use_ro t.mutex (fun () -> (t.bar_subs, t.trade_subs, t.public_trade_subs))
    in
    let token = Auth.current t.auth in
    let send_bars (instrument, timeframe) =
      let j = Ws.Requests.Bars.subscribe ~token ~instrument ~timeframe in
      match t.conn with
      | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
      | None -> ()
    in
    let send_trades account_id =
      let j = Ws.Requests.Trades.subscribe ~token ~account_id in
      match t.conn with
      | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
      | None -> ()
    in
    let send_public_trades instrument =
      let j = Ws.Requests.Public_trades.subscribe ~token instrument in
      match t.conn with
      | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
      | None -> ()
    in
    SubMap.iter (fun key _ -> send_bars key) bar_subs;
    StringSet.iter send_trades trade_subs;
    InstrSet.iter send_public_trades public_trade_subs
  in
  let make_conn () =
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
        on_disconnect =
          (fun () ->
            match !t_ref with
            | None -> ()
            | Some t ->
                let listeners =
                  Eio.Mutex.use_ro t.mutex (fun () -> t.disconnect_listeners)
                in
                fire_listeners listeners);
        on_reconnect =
          (fun () ->
            match !t_ref with
            | None -> ()
            | Some t ->
                resubscribe_all t ();
                let listeners =
                  Eio.Mutex.use_ro t.mutex (fun () -> t.reconnect_listeners)
                in
                fire_listeners listeners);
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
      trade_subs = StringSet.empty;
      public_trade_subs = InstrSet.empty;
      next_listener_id = 0;
      disconnect_listeners = [];
      reconnect_listeners = [];
      make_conn;
    }
  in
  t_ref := Some t;
  t

let register_lifecycle (t : bridge) ~on_disconnect ~on_reconnect : listener_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let id = t.next_listener_id in
      t.next_listener_id <- id + 1;
      t.disconnect_listeners <- (id, on_disconnect) :: t.disconnect_listeners;
      t.reconnect_listeners <- (id, on_reconnect) :: t.reconnect_listeners;
      id)

let unregister_lifecycle (t : bridge) (id : listener_id) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.disconnect_listeners <- List.filter (fun (i, _) -> i <> id) t.disconnect_listeners;
      t.reconnect_listeners <- List.filter (fun (i, _) -> i <> id) t.reconnect_listeners)

let send_subscribe t ~instrument ~timeframe =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Bars.subscribe ~token ~instrument ~timeframe in
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
  | None -> ()

let send_subscribe_trades t ~account_id =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Trades.subscribe ~token ~account_id in
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
  | None -> ()

let ensure_conn t =
  match t.conn with
  | Some c -> c
  | None ->
      let c = t.make_conn () in
      t.conn <- Some c;
      c

let subscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      ignore (ensure_conn t);
      t.bar_subs <- SubMap.add (instrument, timeframe) timeframe t.bar_subs);
  send_subscribe t ~instrument ~timeframe

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Bars.unsubscribe ~token ~instrument ~timeframe in
  let should_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.bar_subs <- SubMap.remove (instrument, timeframe) t.bar_subs;
        SubMap.is_empty t.bar_subs
        && StringSet.is_empty t.trade_subs
        && InstrSet.is_empty t.public_trade_subs)
  in
  match t.conn with
  | Some c ->
      Websocket.Resilient.send c (Yojson.Safe.to_string j);
      if should_close then begin
        Websocket.Resilient.close c;
        t.conn <- None
      end
  | None -> ()

let subscribe_trades (t : bridge) ~(account_id : string) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      ignore (ensure_conn t);
      t.trade_subs <- StringSet.add account_id t.trade_subs);
  send_subscribe_trades t ~account_id

let unsubscribe_trades (t : bridge) ~(account_id : string) : unit =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Trades.unsubscribe ~token ~account_id in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.trade_subs <- StringSet.remove account_id t.trade_subs);
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
  | None -> ()

let send_subscribe_public_trades t ~instrument =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Public_trades.subscribe ~token instrument in
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string j)
  | None -> ()

let subscribe_public_trades (t : bridge) ~(instrument : Instrument.t) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      ignore (ensure_conn t);
      t.public_trade_subs <- InstrSet.add instrument t.public_trade_subs);
  send_subscribe_public_trades t ~instrument

let unsubscribe_public_trades (t : bridge) ~(instrument : Instrument.t) : unit =
  let token = Auth.current t.auth in
  let j = Ws.Requests.Public_trades.unsubscribe ~token instrument in
  let should_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.public_trade_subs <- InstrSet.remove instrument t.public_trade_subs;
        SubMap.is_empty t.bar_subs
        && StringSet.is_empty t.trade_subs
        && InstrSet.is_empty t.public_trade_subs)
  in
  match t.conn with
  | Some c ->
      Websocket.Resilient.send c (Yojson.Safe.to_string j);
      if should_close then begin
        Websocket.Resilient.close c;
        t.conn <- None
      end
  | None -> ()

(** Alor WebSocket bridge — thin wrapper over {!Websocket.Resilient}.

    One multiplexed socket carries bar streams plus the account-wide
    fill stream. Alor correlates every inbound frame solely by the
    client-chosen [guid] (the data payload carries no instrument /
    timeframe / channel marker), so the bridge keeps a [guid → target]
    registry and uses it to enrich each frame back into a typed
    {!Ws.event} before handing it to [on_event].

    On reconnect the bridge resubscribes every known stream, reusing
    the original guids so the registry stays valid. A parallel
    lifecycle-listener registry lets external transport supervisors
    react to the same WS health transitions (mirrors {!Finam.Ws_bridge}). *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t

  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)
module GuidMap = Map.Make (String)
module InstrMap = Map.Make (Instrument)

(** What a subscription guid resolves to on the inbound side. *)
type target = Bars of SubKey.t | Trades | Public_trades of Instrument.t

type listener_id = int

type bridge = {
  cfg : Config.t;
  auth : Auth.t;
  on_event : Ws.event -> unit;
  mutex : Eio.Mutex.t;
  mutable conn : Websocket.Resilient.t option;
  mutable bar_guids : string SubMap.t;  (** [(instrument, timeframe) → guid] *)
  mutable trades_guid : string option;  (** guid of the account-wide fill stream *)
  mutable public_trade_guids : string InstrMap.t;
      (** [instrument → guid] (public tape) *)
  mutable targets : target GuidMap.t;  (** reverse map for inbound frame routing *)
  mutable next_listener_id : listener_id;
  mutable disconnect_listeners : (listener_id * (unit -> unit)) list;
  mutable reconnect_listeners : (listener_id * (unit -> unit)) list;
  make_conn : unit -> Websocket.Resilient.t;
}

let new_guid () = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let fire_listeners (listeners : (listener_id * (unit -> unit)) list) : unit =
  List.iter
    (fun (_, f) ->
      try f () with e -> Log.warn "[alor ws] listener raised: %s" (Printexc.to_string e))
    listeners

let send t json =
  match t.conn with
  | Some c -> Websocket.Resilient.send c (Yojson.Safe.to_string json)
  | None -> ()

(** Route one inbound data frame to [on_event], recovering the
    instrument/timeframe (bars) or wire DTO (trades) from the guid. *)
let handle_frame t ({ guid; data } : Ws.frame) : unit =
  let target = Eio.Mutex.use_ro t.mutex (fun () -> GuidMap.find_opt guid t.targets) in
  match target with
  | Some (Bars (instrument, timeframe)) -> (
      try t.on_event (Ws.Bar { instrument; timeframe; candle = Ws.Events.Bar.parse data })
      with e -> Log.warn "[alor ws] bar decode failed: %s" (Printexc.to_string e))
  | Some Trades -> (
      try t.on_event (Ws.Trade (Ws.Events.Trade.parse data))
      with e -> Log.warn "[alor ws] trade decode failed: %s" (Printexc.to_string e))
  | Some (Public_trades instrument) -> (
      try t.on_event (Ws.Public_trades (Ws.Events.Public_trades.parse ~instrument data))
      with e ->
        Log.warn "[alor ws] public-trade decode failed: %s" (Printexc.to_string e))
  | None -> Log.info "[alor ws] frame for unknown guid %s — dropping" guid

let resubscribe_all (t : bridge) () : unit =
  let bar_guids, trades_guid, public_trade_guids =
    Eio.Mutex.use_ro t.mutex (fun () ->
        (t.bar_guids, t.trades_guid, t.public_trade_guids))
  in
  let token = Auth.current t.auth in
  SubMap.iter
    (fun (instrument, timeframe) guid ->
      send t
        (Ws.Requests.Bars.subscribe ~cfg:t.cfg ~token ~guid ~instrument ~timeframe ()))
    bar_guids;
  InstrMap.iter
    (fun instrument guid ->
      send t (Ws.Requests.Public_trades.subscribe ~cfg:t.cfg ~token ~guid ~instrument ()))
    public_trade_guids;
  match trades_guid with
  | Some guid -> send t (Ws.Requests.Trades.subscribe ~cfg:t.cfg ~token ~guid ())
  | None -> ()

let make ~env ~sw ~cfg ~auth ~on_event : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        Log.warn "[alor ws] CA load failed: %s" m;
        None
  in
  let t_ref = ref None in
  let make_conn () =
    let config : Websocket.Resilient.config =
      {
        label = "alor ws";
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
                match Yojson.Safe.from_string payload with
                | exception e ->
                    Log.warn "[alor ws] non-json frame: %s raw: %s" (Printexc.to_string e)
                      payload
                | j -> (
                    match Ws.frame_of_json j with
                    | Some f -> handle_frame t f
                    | None -> ())));
        on_disconnect =
          (fun () ->
            match !t_ref with
            | None -> ()
            | Some t ->
                fire_listeners
                  (Eio.Mutex.use_ro t.mutex (fun () -> t.disconnect_listeners)));
        on_reconnect =
          (fun () ->
            match !t_ref with
            | None -> ()
            | Some t ->
                resubscribe_all t ();
                fire_listeners
                  (Eio.Mutex.use_ro t.mutex (fun () -> t.reconnect_listeners)));
      }
    in
    Websocket.Resilient.create ~env ~sw ~config
  in
  let t =
    {
      cfg;
      auth;
      on_event;
      mutex = Eio.Mutex.create ();
      conn = None;
      bar_guids = SubMap.empty;
      trades_guid = None;
      public_trade_guids = InstrMap.empty;
      targets = GuidMap.empty;
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

let ensure_conn t =
  match t.conn with
  | Some c -> c
  | None ->
      let c = t.make_conn () in
      t.conn <- Some c;
      c

let subscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let key = (instrument, timeframe) in
  let token = Auth.current t.auth in
  let guid =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        ignore (ensure_conn t);
        match SubMap.find_opt key t.bar_guids with
        | Some g -> g
        | None ->
            let g = new_guid () in
            t.bar_guids <- SubMap.add key g t.bar_guids;
            t.targets <- GuidMap.add g (Bars key) t.targets;
            g)
  in
  send t (Ws.Requests.Bars.subscribe ~cfg:t.cfg ~token ~guid ~instrument ~timeframe ())

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let key = (instrument, timeframe) in
  let token = Auth.current t.auth in
  let guid_opt, should_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match SubMap.find_opt key t.bar_guids with
        | None -> (None, false)
        | Some g ->
            t.bar_guids <- SubMap.remove key t.bar_guids;
            t.targets <- GuidMap.remove g t.targets;
            ( Some g,
              SubMap.is_empty t.bar_guids && Option.is_none t.trades_guid
              && InstrMap.is_empty t.public_trade_guids ))
  in
  match guid_opt with
  | None -> ()
  | Some guid -> (
      send t (Ws.Requests.Unsubscribe.make ~token ~guid);
      if should_close then
        match t.conn with
        | Some c ->
            Websocket.Resilient.close c;
            t.conn <- None
        | None -> ())

let subscribe_trades (t : bridge) : unit =
  let token = Auth.current t.auth in
  let guid =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        ignore (ensure_conn t);
        match t.trades_guid with
        | Some g -> g
        | None ->
            let g = new_guid () in
            t.trades_guid <- Some g;
            t.targets <- GuidMap.add g Trades t.targets;
            g)
  in
  send t (Ws.Requests.Trades.subscribe ~cfg:t.cfg ~token ~guid ())

let unsubscribe_trades (t : bridge) : unit =
  let token = Auth.current t.auth in
  let guid_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match t.trades_guid with
        | None -> None
        | Some g ->
            t.trades_guid <- None;
            t.targets <- GuidMap.remove g t.targets;
            Some g)
  in
  match guid_opt with
  | None -> ()
  | Some guid -> send t (Ws.Requests.Unsubscribe.make ~token ~guid)

(* Public tape (AllTradesGetAndSubscribe): one guid per instrument on
   the shared multiplexed socket. WS-only — no Transport_supervisor
   (the footprint domain is fold-order-independent; dedup is the
   inbox's concern). *)
let subscribe_public_trades (t : bridge) ~instrument : unit =
  let token = Auth.current t.auth in
  let guid =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        ignore (ensure_conn t);
        match InstrMap.find_opt instrument t.public_trade_guids with
        | Some g -> g
        | None ->
            let g = new_guid () in
            t.public_trade_guids <- InstrMap.add instrument g t.public_trade_guids;
            t.targets <- GuidMap.add g (Public_trades instrument) t.targets;
            g)
  in
  send t (Ws.Requests.Public_trades.subscribe ~cfg:t.cfg ~token ~guid ~instrument ())

let unsubscribe_public_trades (t : bridge) ~instrument : unit =
  let token = Auth.current t.auth in
  let guid_opt, should_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match InstrMap.find_opt instrument t.public_trade_guids with
        | None -> (None, false)
        | Some g ->
            t.public_trade_guids <- InstrMap.remove instrument t.public_trade_guids;
            t.targets <- GuidMap.remove g t.targets;
            ( Some g,
              SubMap.is_empty t.bar_guids && Option.is_none t.trades_guid
              && InstrMap.is_empty t.public_trade_guids ))
  in
  match guid_opt with
  | None -> ()
  | Some guid -> (
      send t (Ws.Requests.Unsubscribe.make ~token ~guid);
      if should_close then
        match t.conn with
        | Some c ->
            Websocket.Resilient.close c;
            t.conn <- None
        | None -> ())

(** Adapter: exposes {!Rest.t} + {!Ws_bridge} through the
    broker-agnostic {!Broker.S} interface. All Alor-specific
    translation lives here so callers program against
    {!Broker.client}.

    {b Order identity at the port.} The placement-keyed methods speak
    [placement_id : int]. Alor assigns the order id itself (no
    caller-supplied client-order-id): {!place_order} records the
    returned [orderNumber] in a private {!Placement_handle_store}, and
    cancel / status / fill lookups resolve through it. Alor handles
    never cross this boundary.

    {b Exchange scoping.} Alor's account endpoints (cancel, get-order,
    trades) are keyed by [(exchange, portfolio)]. The placement store
    holds no exchange, so account-side calls use the config's
    [default_exchange]; this adapter is therefore single-exchange per
    instance (matching the MOEX-only posture of the BCS adapter). A
    multi-exchange portfolio would store the exchange alongside the
    order id — a localised follow-up.

    {b Live feeds.} The adapter owns the multiplexed WS bridge, the
    per-(instrument, timeframe) bar supervisors, and one account-wide
    fill supervisor. Each runs WS-primary with a REST-poll fallback via
    {!Acl_common.Transport_supervisor}; consumers see one
    {!Broker.event} stream regardless of which transport delivered it. *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t

  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)

type t = {
  rest : Rest.t;
  placements : Placement_handle_store.t;
  bar_dedup : (Instrument.t * Timeframe.t, Candle.t) Acl_common.Stream_dedup.t;
  fill_dedup :
    (int, Broker_domain.Remote_broker.Events.Trade_executed.t) Acl_common.Stream_dedup.t;
      (** Per-placement fill dedup shared by the WS and REST-poll
          branches; keyed by [placement_id], equal by [trade_id]
          (Alor's trade [id], stable across both transports). *)
  mutex : Eio.Mutex.t;
  mutable bridge : Ws_bridge.bridge option;
  mutable on_event : (Broker.event -> unit) option;
  mutable bar_refcount : int SubMap.t;
  mutable bar_supervisors : Candle.t Acl_common.Transport_supervisor.t SubMap.t;
  mutable bar_supervisor_listeners : (SubKey.t * Ws_bridge.listener_id) list;
  mutable fill_supervisor :
    Broker_domain.Remote_broker.Events.Trade_executed.t Acl_common.Transport_supervisor.t
    option;
  mutable live_feed_ctx : (Eio.Switch.t * Eio_unix.Stdenv.base) option;
}

let name = "alor"

let make (rest : Rest.t) : t =
  let fill_equal
      (a : Broker_domain.Remote_broker.Events.Trade_executed.t)
      (b : Broker_domain.Remote_broker.Events.Trade_executed.t) : bool =
    String.equal a.trade_id b.trade_id
  in
  {
    rest;
    placements = Placement_handle_store.create ();
    bar_dedup = Acl_common.Stream_dedup.create ~equal_value:Candle.equal;
    fill_dedup = Acl_common.Stream_dedup.create ~equal_value:fill_equal;
    mutex = Eio.Mutex.create ();
    bridge = None;
    on_event = None;
    bar_refcount = SubMap.empty;
    bar_supervisors = SubMap.empty;
    bar_supervisor_listeners = [];
    fill_supervisor = None;
    live_feed_ctx = None;
  }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe

(** Alor routes to MOEX ([MISX]) and SPB Exchange ([XSPB]). Display
    labels are the UI's concern; we surface the raw MICs. *)
let venues _t : Mic.t list = [ Mic.of_string "MISX"; Mic.of_string "XSPB" ]

let default_exchange t = (Rest.cfg t.rest).Config.default_exchange

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif :
    Broker_domain.Order.t =
  (* MOEX equities trade in integer lots; the port speaks [Decimal.t]
     for uniformity, so truncate via float (adequate for lot sizes). *)
  let q_int = int_of_float (Decimal.to_float quantity) in
  (* Stamp the saga's placement_id into Alor's [comment] so the order
     stays identifiable at the venue (recovery anchor) — the closest
     analog to Finam/BCS minting a client-order-id before the call. *)
  let order_id =
    Rest.place_order t.rest ~instrument ~side ~quantity:q_int ~kind ~tif
      ~comment:(string_of_int placement_id)
  in
  (match Placement_handle_store.record t.placements ~placement_id ~order_id with
  | `Ok | `Already_exists -> ());
  (* Alor's placement response carries only [orderNumber] + a success
     message — not a full order object. A 2xx means the venue accepted
     the order, so we report the just-submitted parameters with
     [status = New]; subsequent state arrives via get-order / fills. *)
  {
    placement_id;
    instrument;
    side;
    quantity;
    filled = Decimal.zero;
    kind;
    tif;
    status = New;
    placed_ts = Int64.of_float (Unix.gettimeofday ());
  }

let cancel_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_order_id t.placements ~placement_id with
  | None -> None
  | Some order_id ->
      let exchange = default_exchange t in
      (* Snapshot the order for its descriptive fields, then cancel.
         A successful DELETE (2xx) is Alor's authoritative confirmation
         that the order was removed — anything uncancellable (already
         filled / unknown) returns non-2xx and raises here, surfacing
         as Unreachable upstream. So we report [Cancelled] on success. *)
      let dto = Rest.get_order t.rest ~exchange ~order_id in
      Rest.cancel_order t.rest ~exchange ~order_id;
      Some (Dto.Order.to_domain ~placement_id { dto with status = Cancelled })

let get_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_order_id t.placements ~placement_id with
  | None -> None
  | Some order_id ->
      let dto = Rest.get_order t.rest ~exchange:(default_exchange t) ~order_id in
      Some (Dto.Order.to_domain ~placement_id dto)

let get_trades t ~placement_id : Broker_domain.Order.Trade.t list =
  match Placement_handle_store.find_order_id t.placements ~placement_id with
  | None -> []
  | Some order_id ->
      Rest.get_trades t.rest ~exchange:(default_exchange t)
      |> List.filter_map (fun (dt : Dto.Trade.t) ->
          if String.equal dt.order_id order_id then Some dt.trade else None)

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event with e -> Log.warn "[alor] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Lift one Alor trade DTO into the domain fill event, resolving its
    parent order id to a [placement_id]. [None] when the fill is for an
    order this adapter never placed (or whose mapping rotated out). *)
let trade_executed_of_dto t (dt : Dto.Trade.t) :
    Broker_domain.Remote_broker.Events.Trade_executed.t option =
  match Placement_handle_store.find_placement_id t.placements ~order_id:dt.order_id with
  | None ->
      Log.warn "[alor] trade for unknown order_id=%s — skipping" dt.order_id;
      None
  | Some placement_id -> Some (Ws.Events.Trade.to_domain ~placement_id dt)

let finalize_and_dispatch_fill
    t
    (raw : Broker_domain.Remote_broker.Events.Trade_executed.t) : unit =
  dispatch t (Broker.Trade_executed raw)

(** WS callback (set on the bridge): route a resolved {!Ws.event} to
    the matching supervisor. Dedup is the supervisor's job (shared
    [Stream_dedup] with the REST-poll branch). *)
let dispatch_ws_event t (ev : Ws.event) : unit =
  match ev with
  | Ws.Bar { instrument; timeframe; candle } -> (
      let key = (instrument, timeframe) in
      match
        Eio.Mutex.use_ro t.mutex (fun () -> SubMap.find_opt key t.bar_supervisors)
      with
      | Some sup -> Acl_common.Transport_supervisor.feed_ws sup candle
      | None ->
          Log.info "[alor ws] bars for unregistered key %s/%s — dropping"
            (Instrument.to_qualified instrument)
            (Timeframe.to_string timeframe))
  | Ws.Trade dt -> (
      match t.fill_supervisor with
      | None -> Log.warn "[alor ws] trade arrived before fill_supervisor — dropping"
      | Some sup -> (
          match trade_executed_of_dto t dt with
          | Some raw -> Acl_common.Transport_supervisor.feed_ws sup raw
          | None -> ()))

(** REST-poll branch of the fill supervisor: pull the portfolio's
    current-session trades and lift the ones we recognise. Alor's
    [/trades] is session-scoped (no time cursor), so [since_ts] /
    [to_ts] are unused here — the supervisor's [Stream_dedup] (by
    [trade_id]) suppresses the re-observed legs. *)
let fill_poll_window t ~since_ts:_ ~to_ts:_ :
    Broker_domain.Remote_broker.Events.Trade_executed.t list =
  try
    Rest.get_trades t.rest ~exchange:(default_exchange t)
    |> List.filter_map (trade_executed_of_dto t)
  with e ->
    Log.warn "[alor] fill poll failed: %s" (Printexc.to_string e);
    []

let with_bridge t f =
  match t.bridge with
  | None -> Log.warn "[alor] subscribe/unsubscribe before start_live_feed — ignored"
  | Some bridge -> f bridge

(** Build the per-(instrument, timeframe) bar supervisor and wire it
    into the bridge's lifecycle registry. *)
let make_bar_supervisor t bridge ~sw ~env ~instrument ~timeframe :
    Candle.t Acl_common.Transport_supervisor.t * Ws_bridge.listener_id =
  let ts_now () = Int64.of_float (Unix.gettimeofday ()) in
  let dedup_accept (candle : Candle.t) =
    Acl_common.Stream_dedup.should_accept t.bar_dedup ~key:(instrument, timeframe)
      ~ts:candle.ts ~value:candle
  in
  let poll_window ~since_ts ~to_ts =
    try Rest.bars ~from_ts:since_ts ~to_ts ~n:500 t.rest ~instrument ~timeframe
    with e ->
      Log.warn "[alor] bars poll %s/%s failed: %s"
        (Instrument.to_qualified instrument)
        (Timeframe.to_string timeframe)
        (Printexc.to_string e);
      []
  in
  let emit (candle : Candle.t) =
    dispatch t
      (Broker.Remote_bar_updated
         {
           Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument;
           timeframe;
           candle;
         })
  in
  let label =
    Printf.sprintf "alor bars %s/%s"
      (Instrument.to_qualified instrument)
      (Timeframe.to_string timeframe)
  in
  let sup =
    Acl_common.Transport_supervisor.start ~env ~sw ~label ~poll_interval:60.0 ~ts_now
      ~poll_window
      ~ts_of_event:(fun (c : Candle.t) -> c.ts)
      ~dedup_accept ~emit ~initial_since_ts:(ts_now ())
  in
  let listener_id =
    Ws_bridge.register_lifecycle bridge
      ~on_disconnect:(fun () -> Acl_common.Transport_supervisor.ws_went_down sup)
      ~on_reconnect:(fun () -> Acl_common.Transport_supervisor.ws_reconnected sup)
  in
  (sup, listener_id)

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  t.live_feed_ctx <- Some (sw, env);
  let cfg = Rest.cfg t.rest in
  let auth = Rest.auth t.rest in
  let bridge = Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event:(dispatch_ws_event t) in
  t.bridge <- Some bridge;
  let ts_now () = Int64.of_float (Unix.gettimeofday ()) in
  let dedup_accept (ev : Broker_domain.Remote_broker.Events.Trade_executed.t) =
    Acl_common.Stream_dedup.should_accept t.fill_dedup ~key:ev.placement_id ~ts:ev.ts
      ~value:ev
  in
  let sup =
    Acl_common.Transport_supervisor.start ~env ~sw ~label:"alor fills" ~poll_interval:5.0
      ~ts_now
      ~poll_window:(fun ~since_ts ~to_ts -> fill_poll_window t ~since_ts ~to_ts)
      ~ts_of_event:(fun ev -> ev.Broker_domain.Remote_broker.Events.Trade_executed.ts)
      ~dedup_accept
      ~emit:(finalize_and_dispatch_fill t)
      ~initial_since_ts:(ts_now ())
  in
  t.fill_supervisor <- Some sup;
  let _ : Ws_bridge.listener_id =
    Ws_bridge.register_lifecycle bridge
      ~on_disconnect:(fun () -> Acl_common.Transport_supervisor.ws_went_down sup)
      ~on_reconnect:(fun () -> Acl_common.Transport_supervisor.ws_reconnected sup)
  in
  (* Always-on account-wide fills subscription, multiplexed on the same
     socket as bars. WS-success is signalled to the supervisor only
     once subscribe_trades returns without raising. *)
  try
    Ws_bridge.subscribe_trades bridge;
    Acl_common.Transport_supervisor.ws_came_up sup
  with e -> Log.warn "[alor ws] subscribe_trades failed: %s" (Printexc.to_string e)

let subscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } ->
      let key = (instrument, timeframe) in
      let should_send_upstream =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            let prev =
              match SubMap.find_opt key t.bar_refcount with
              | Some n -> n
              | None -> 0
            in
            t.bar_refcount <- SubMap.add key (prev + 1) t.bar_refcount;
            prev = 0)
      in
      if should_send_upstream then
        with_bridge t (fun bridge ->
            match t.live_feed_ctx with
            | None ->
                Log.warn "[alor] subscribe_bars before start_live_feed ctx — ignored"
            | Some (sw, env) -> (
                let sup, listener_id =
                  make_bar_supervisor t bridge ~sw ~env ~instrument ~timeframe
                in
                Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                    t.bar_supervisors <- SubMap.add key sup t.bar_supervisors;
                    t.bar_supervisor_listeners <-
                      (key, listener_id) :: t.bar_supervisor_listeners);
                try
                  Ws_bridge.subscribe_bars bridge ~instrument ~timeframe;
                  Acl_common.Transport_supervisor.ws_came_up sup
                with e ->
                  Log.warn "[alor ws] subscribe_bars failed: %s" (Printexc.to_string e)))
  | Subscribe_public_trades _ ->
      Log.info
        "[alor ws] public-trade (AllTrades) subscription not yet supported — ignored"

let unsubscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } ->
      let key = (instrument, timeframe) in
      let should_send_upstream =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            match SubMap.find_opt key t.bar_refcount with
            | None | Some 0 -> false
            | Some 1 ->
                t.bar_refcount <- SubMap.remove key t.bar_refcount;
                true
            | Some n ->
                t.bar_refcount <- SubMap.add key (n - 1) t.bar_refcount;
                false)
      in
      if should_send_upstream then
        with_bridge t (fun bridge ->
            let sup_opt, listener_opt =
              Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                  let sup = SubMap.find_opt key t.bar_supervisors in
                  let listener = List.assoc_opt key t.bar_supervisor_listeners in
                  t.bar_supervisors <- SubMap.remove key t.bar_supervisors;
                  t.bar_supervisor_listeners <-
                    List.filter
                      (fun (k, _) -> SubKey.compare k key <> 0)
                      t.bar_supervisor_listeners;
                  (sup, listener))
            in
            Option.iter (Ws_bridge.unregister_lifecycle bridge) listener_opt;
            Option.iter Acl_common.Transport_supervisor.stop sup_opt;
            try Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
            with e ->
              Log.warn "[alor ws] unsubscribe_bars failed: %s" (Printexc.to_string e))
  | Subscribe_public_trades _ -> ()

let as_broker (t : t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t

      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let cancel_order = cancel_order
      let get_order = get_order
      let get_trades = get_trades
      let start_live_feed = start_live_feed
      let subscribe = subscribe
      let unsubscribe = unsubscribe
    end)
    t

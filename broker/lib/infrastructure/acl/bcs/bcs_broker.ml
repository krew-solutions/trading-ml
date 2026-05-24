(** Adapter from [Bcs.Rest.t] to [Broker.S]. Symmetric to
    [Finam_broker]: returns the venues this broker can route to as MIC
    codes. BCS-via-QUIK is MOEX-only in our setup, so this is a single
    static MIC; the per-board distinction (TQBR/SPBFUT/...) lives on
    the {!Instrument.t} as [board], not here.

    {b Order identity at the port.} The placement-keyed methods
    speak [placement_id : int]. The adapter mints a BCS-format
    [client_order_id] (dashed UUIDv4 — BCS's validator rejects any
    other shape) on submit and records the linkage in a private
    {!Placement_handle_store}. Cancel / get / get_trades
    resolve through that store; [None] when the placement was
    never observed by this adapter.

    {b Order identity at venue.} BCS uses the caller-supplied
    [clientOrderId] as the server-side id too, so once a
    placement is bound to a [client_order_id] the venue echoes
    the same string back; no separate cid↔server-id map.

    Quantity conversion: the port speaks [Decimal.t] for uniformity,
    but BCS's REST wire format wants a plain integer (MOEX equities
    trade in integer lots). We truncate via float — precision is
    adequate for lot-sized quantities.

    Time-in-force is silently ignored: BCS doesn't expose a TIF field
    on create_order, every order is effectively DAY.

    {b Live feeds.} Unlike Finam's multiplexed socket, BCS opens
    one WS connection per (instrument, timeframe) for market
    data, plus one account-wide WS connection for personal
    fills (execution-status channel). Account fills run
    behind an {!Acl_common.Transport_supervisor}: WS is the
    primary transport, REST [get_deals] polling is the
    fallback that activates whenever the WS disconnects and
    deactivates on reconnect. The supervisor is invisible
    to consumers — {!Broker.event} fires the same regardless
    of which transport delivered the leg. *)

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
  mutex : Eio.Mutex.t;
  mutable bridge : Ws_bridge.bridge option;
  mutable on_event : (Broker.event -> unit) option;
  mutable bar_refcount : int SubMap.t;
  total_filled : (int, Decimal.t) Acl_common.Cumulative_sum.t;
      (** Per-placement cumulative-fill accumulator. The
          adapter is the recognizer of venue fill facts (per
          Vernon's "external system as a source of Domain
          Events"); the cumulative is bookkeeping derived from
          the sequence of observed legs and lives here, with
          the recognizer, rather than leaking into the
          application layer. *)
  fill_dedup :
    (int, Broker_domain.Remote_broker.Events.Order_filled.t) Acl_common.Stream_dedup.t;
      (** Per-placement fill-stream deduplicator. Shared
          between the WS execution-status branch and the REST
          [get_deals] fallback branch so the same fill never
          crosses the ACL boundary twice. Keyed by
          [placement_id]; [equal_value] compares [trade_id]
          since BCS surfaces it on both wire paths — WS as
          [executionId], REST as [tradeNum]. *)
  bar_dedup : (Instrument.t * Timeframe.t, Candle.t) Acl_common.Stream_dedup.t;
      (** Inbound bar-stream deduplicator: drops stale snapshots
          and exact intra-period duplicates before they cross
          the ACL boundary into the domain. Co-located with the
          recognizer because duplicate suppression is part of
          fact recognition — a second observation of the same
          fact at the same ts is not a new fact. *)
}

let name = "bcs"

let make (rest : Rest.t) : t =
  let fill_equal
      (a : Broker_domain.Remote_broker.Events.Order_filled.t)
      (b : Broker_domain.Remote_broker.Events.Order_filled.t) : bool =
    String.equal a.trade_id b.trade_id
  in
  {
    rest;
    placements = Placement_handle_store.create ();
    mutex = Eio.Mutex.create ();
    bridge = None;
    on_event = None;
    bar_refcount = SubMap.empty;
    total_filled = Acl_common.Cumulative_sum.create ~zero:Decimal.zero ~add:Decimal.add;
    fill_dedup = Acl_common.Stream_dedup.create ~equal_value:fill_equal;
    bar_dedup = Acl_common.Stream_dedup.create ~equal_value:Candle.equal;
  }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe
let venues _t : Mic.t list = [ Mic.of_string "MISX" ]

(** UUIDv4 in canonical dashed form — BCS validates [clientOrderId]
    as "UUID format" and 400s on anything else. *)
let mint_client_order_id () =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif:_ :
    Broker_domain.Order.t =
  let cid = mint_client_order_id () in
  (match
     Placement_handle_store.record t.placements ~placement_id ~client_order_id:cid
   with
  | `Ok | `Already_exists -> ());
  let q_int = int_of_float (Decimal.to_float quantity) in
  let external_order =
    Rest.create_order t.rest ~instrument ~side ~quantity:q_int ~kind ~client_order_id:cid
      ()
  in
  Dto.Order.to_domain ~placement_id external_order

let cancel_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let external_order = Rest.cancel_order t.rest ~client_order_id:cid in
      Some (Dto.Order.to_domain ~placement_id external_order)

let get_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let external_order = Rest.get_order t.rest ~client_order_id:cid in
      Some (Dto.Order.to_domain ~placement_id external_order)

(** Project account-wide deals into per-execution records for the
    placement identified by [placement_id]. BCS's deal payload
    does not carry [clientOrderId] — only [orderNum]
    (broker-assigned). So we resolve the order first to pick up
    its [exec_id] (= the [orderNum] BCS kept on [Dto.Order.t]),
    then filter the deals list by string-equality on that id.
    Returns [] if the placement is unknown, has no [exec_id] yet
    (still pending), or no fills against it. *)
let get_trades t ~placement_id : Broker_domain.Order.trade list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let external_order = Rest.get_order t.rest ~client_order_id:cid in
      if external_order.exec_id = "" then []
      else
        Rest.get_deals t.rest
        |> List.filter_map (fun (e : Dto.Execution.t) ->
            if e.order_num = external_order.exec_id then
              Some
                {
                  Broker_domain.Order.ts = e.ts;
                  quantity = e.quantity;
                  price = e.price;
                  fee = e.fee;
                }
            else None)

(** Reverse lookup [order_num → placement_id]. In BCS the
    venue-side identifier echoed back on deals (the [orderNum]
    in [/trades/search] payloads) {b is} the same
    [clientOrderId] we minted at submit — BCS uses the
    caller-supplied id as the server-side handle. So this hop
    is a direct [Placement_handle_store.find_placement_id]
    over the same string; we still wrap it as its own function
    to mirror Finam's adapter shape and so a future BCS server-
    side id change becomes a single-callsite edit. *)
let placement_id_by_order_num t ~order_num : int option =
  Placement_handle_store.find_placement_id t.placements ~client_order_id:order_num

(** Account-wide deal feed for the recent window: thin
    pass-through to [Rest.get_deals] (which polls
    [/trade-api-bff-trade-details/api/v1/trades/search]). Used
    by the broker's WS-equivalent polling fiber to discover new
    fills outside command-in-scope. Returns BCS's
    [Dto.Execution.t]s verbatim; callers filter to their
    own placements via [placement_id_by_order_num]. *)
let recent_deals ?from_ts ?to_ts t : Dto.Execution.t list =
  Rest.get_deals ?from_ts ?to_ts t.rest

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event with e -> Log.warn "[bcs] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Convert a single REST-deal record into a (raw) domain event
    suitable for funnelling into the fill supervisor. The
    [new_total_filled] field is a placeholder ([Decimal.zero]):
    the final value is computed by {!finalize_and_dispatch}
    after dedup, so that catch-up replays of an already-seen
    fill don't double-count the cumulative. *)
let order_filled_of_rest t (e : Dto.Execution.t) :
    Broker_domain.Remote_broker.Events.Order_filled.t option =
  match placement_id_by_order_num t ~order_num:e.order_num with
  | None -> None
  | Some placement_id ->
      Some
        {
          placement_id;
          trade_id = e.trade_id;
          instrument = e.instrument;
          side = e.side;
          fill_quantity = e.quantity;
          fill_price = e.price;
          fee = e.fee;
          fill_ts = e.ts;
          new_total_filled = Decimal.zero;
        }

(** REST-side branch of the supervisor's [poll_window]:
    pulls deals over [(since_ts, to_ts)], drops the ones we
    can't map back to a known placement, and returns raw domain
    events (cumulative-bump happens at the seam, not here). *)
let poll_fill_window t ~since_ts ~to_ts :
    Broker_domain.Remote_broker.Events.Order_filled.t list =
  recent_deals ~from_ts:since_ts ~to_ts t |> List.filter_map (order_filled_of_rest t)

(** WS-side branch: takes a parsed BCS execution-status event,
    looks up the placement, and returns a (raw, not finalised)
    domain event. Returns [None] when the event is not a fill
    (lifecycle events on this channel are dropped silently) or
    when the placement is unknown (the broker may report fills
    on orders placed by another session sharing the
    [original_client_order_id] — not our problem). *)
let order_filled_of_ws t (ev : Ws.Events.Order_event.t) :
    Broker_domain.Remote_broker.Events.Order_filled.t option =
  if not (Ws.Events.Order_event.is_fill ev) then None
  else
    let cid = ev.original_client_order_id in
    match Placement_handle_store.find_placement_id t.placements ~client_order_id:cid with
    | None ->
        Log.warn "[bcs order ws] fill for unknown clientOrderId=%s — skipping" cid;
        None
    | Some placement_id ->
        Ws.Events.Order_event.to_domain ~placement_id ~new_total_filled:Decimal.zero ev

(** Common seam for both branches: dedup → cumulative-bump →
    dispatch. The [new_total_filled] supplied on the raw event
    is ignored; the final field is the post-bump cumulative.
    This way a catch-up REST tick that re-emits the same fill
    after a WS dispatch is suppressed at dedup and never bumps
    the accumulator twice. *)
let finalize_and_dispatch t (raw : Broker_domain.Remote_broker.Events.Order_filled.t) :
    unit =
  let new_total =
    Acl_common.Cumulative_sum.bump t.total_filled ~key:raw.placement_id
      ~delta:raw.fill_quantity
  in
  dispatch t (Broker.Order_filled { raw with new_total_filled = new_total })

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  let cfg = Rest.cfg t.rest in
  let auth = Rest.auth t.rest in
  let bridge = Ws_bridge.make ~env ~sw ~cfg ~auth in
  t.bridge <- Some bridge;
  let ts_now () = Int64.of_float (Unix.gettimeofday ()) in
  let initial_since_ts = ts_now () in
  let dedup_accept (ev : Broker_domain.Remote_broker.Events.Order_filled.t) =
    Acl_common.Stream_dedup.should_accept t.fill_dedup ~key:ev.placement_id ~ts:ev.fill_ts
      ~value:ev
  in
  let sup =
    Acl_common.Transport_supervisor.start ~env ~sw ~label:"bcs fills" ~poll_interval:5.0
      ~ts_now
      ~poll_window:(fun ~since_ts ~to_ts -> poll_fill_window t ~since_ts ~to_ts)
      ~ts_of_event:(fun ev -> ev.Broker_domain.Remote_broker.Events.Order_filled.fill_ts)
      ~dedup_accept ~emit:(finalize_and_dispatch t) ~initial_since_ts
  in
  try
    Order_event_bridge.start ~env ~sw ~cfg ~auth
      ~on_event:(fun ev ->
        match order_filled_of_ws t ev with
        | Some raw -> Acl_common.Transport_supervisor.feed_ws sup raw
        | None -> ())
      ~on_disconnect:(fun () -> Acl_common.Transport_supervisor.ws_went_down sup)
      ~on_reconnect:(fun () -> Acl_common.Transport_supervisor.ws_reconnected sup);
    Acl_common.Transport_supervisor.ws_came_up sup
  with e ->
    Log.warn "[bcs] order WS failed to start (%s) — falling back to REST-poll only"
      (Printexc.to_string e)

let with_bridge t f =
  match t.bridge with
  | None -> Log.warn "[bcs] subscribe/unsubscribe before start_live_feed — ignored"
  | Some bridge -> f bridge

let subscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } ->
      let key = (instrument, timeframe) in
      let should_open =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            let prev =
              match SubMap.find_opt key t.bar_refcount with
              | Some n -> n
              | None -> 0
            in
            t.bar_refcount <- SubMap.add key (prev + 1) t.bar_refcount;
            prev = 0)
      in
      if should_open then
        with_bridge t (fun bridge ->
            let dedup_accept (candle : Candle.t) =
              Acl_common.Stream_dedup.should_accept t.bar_dedup
                ~key:(instrument, timeframe) ~ts:candle.ts ~value:candle
            in
            let poll_window ~since_ts ~to_ts =
              (* BCS /candles-chart takes startDate / endDate cursors
                 and caps each request at 1440 bars. Steady-state ticks
                 keep the window narrow (poll_interval = 60s); a
                 reconnect catch-up over a longer gap can hit the cap
                 and 400 — accepted as a known limit, documented in
                 docs/architecture/transport-supervisor.md. *)
              try Rest.bars t.rest ~from_ts:since_ts ~to_ts ~instrument ~timeframe
              with e ->
                Log.warn "[bcs] bars poll %s/%s failed: %s"
                  (Instrument.to_qualified instrument)
                  (Timeframe.to_string timeframe)
                  (Printexc.to_string e);
                []
            in
            let on_candle
                (instrument : Instrument.t)
                (timeframe : Timeframe.t)
                (candle : Candle.t) =
              dispatch t
                (Broker.Remote_bar_updated
                   {
                     Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument;
                     timeframe;
                     candle;
                   })
            in
            try
              Ws_bridge.subscribe_bars bridge ~instrument ~timeframe ~poll_window
                ~dedup_accept ~on_candle
            with e ->
              Log.warn "[bcs ws] subscribe_bars failed: %s" (Printexc.to_string e))

let unsubscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } ->
      let key = (instrument, timeframe) in
      let should_close =
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
      if should_close then
        with_bridge t (fun bridge ->
            try Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
            with e ->
              Log.warn "[bcs ws] unsubscribe_bars failed: %s" (Printexc.to_string e))

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

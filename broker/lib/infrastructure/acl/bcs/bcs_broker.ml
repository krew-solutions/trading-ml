(** Adapter from [Bcs.Rest.t] to [Broker.S]. Symmetric to
    [Finam_broker]: returns the venues this broker can route to as MIC
    codes. BCS-via-QUIK is MOEX-only in our setup, so this is a single
    static MIC; the per-board distinction (TQBR/SPBFUT/...) lives on
    the {!Instrument.t} as [board], not here.

    {b Order identity at the port.} The placement-keyed methods
    speak [placement_id : int]. The adapter mints a BCS-format
    [client_order_id] (dashed UUIDv4 — BCS's validator rejects any
    other shape) on submit and records the linkage in a private
    {!Placement_handle_store}. Cancel / get / get_executions
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
    one WS connection per (instrument, timeframe). The adapter
    owns the bridge and the per-key refcount. Personal-account
    fills are surfaced via a REST-polling fiber for now; BCS's
    WebSocket execution-status / transaction-status channels are
    available and will replace the polling in a future commit. *)

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
  observed_deals : (int * int64 * string * string, unit) Hashtbl.t;
  total_filled : (int, Decimal.t) Acl_common.Cumulative_sum.t;
      (** Per-placement cumulative-fill accumulator. The
          adapter is the recognizer of venue fill facts (per
          Vernon's "external system as a source of Domain
          Events"); the cumulative is bookkeeping derived from
          the sequence of observed legs and lives here, with
          the recognizer, rather than leaking into the
          application layer. *)
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
  {
    rest;
    placements = Placement_handle_store.create ();
    mutex = Eio.Mutex.create ();
    bridge = None;
    on_event = None;
    bar_refcount = SubMap.empty;
    observed_deals = Hashtbl.create 128;
    total_filled = Acl_common.Cumulative_sum.create ~zero:Decimal.zero ~add:Decimal.add;
    bar_dedup = Acl_common.Stream_dedup.create ~equal_value:Candle.equal;
  }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe
let venues _t : Mic.t list = [ Mic.of_string "MISX" ]

(** UUIDv4 in canonical dashed form — BCS validates [clientOrderId]
    as "UUID format" and 400s on anything else. *)
let mint_client_order_id () =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let project ~placement_id (v : External_order.t) : Order_view_model.t =
  Order_view_model.of_domain (External_order.to_broker_domain ~placement_id v)

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif:_ :
    Order_view_model.t =
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
  project ~placement_id external_order

let cancel_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let external_order = Rest.cancel_order t.rest ~client_order_id:cid in
      Some (project ~placement_id external_order)

let get_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let external_order = Rest.get_order t.rest ~client_order_id:cid in
      Some (project ~placement_id external_order)

(** Project account-wide deals into per-execution records for the
    placement identified by [placement_id]. BCS's deal payload
    does not carry [clientOrderId] — only [orderNum]
    (broker-assigned). So we resolve the order first to pick up
    its [exec_id] (= the [orderNum] BCS kept on [External_order.t]),
    then filter the deals list by string-equality on that id.
    Returns [] if the placement is unknown, has no [exec_id] yet
    (still pending), or no fills against it. *)
let get_executions t ~placement_id : Execution_view_model.t list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let external_order = Rest.get_order t.rest ~client_order_id:cid in
      if external_order.exec_id = "" then []
      else
        Rest.get_deals t.rest
        |> List.filter_map (fun (order_num, exec) ->
            if order_num = external_order.exec_id then
              Some (Execution_view_model.of_domain exec)
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
    [(order_num, execution)] pairs verbatim; callers filter to
    their own placements via [placement_id_by_order_num]. *)
let recent_deals ?from_ts ?to_ts t : (string * Broker_domain.Order.trade) list =
  Rest.get_deals ?from_ts ?to_ts t.rest

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event with e -> Log.warn "[bcs] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Polling tick for personal-account fills. Reads recent deals
    via REST, dedups by [(placement_id, ts, qty, price)] tuple,
    emits {!Broker.Order_leg_filled} for every newly-observed fill
    against a placement this adapter recognises. *)
let poll_fills_once t ~env : unit =
  let to_ts = Int64.of_float (Eio.Time.now (Eio.Stdenv.clock env)) in
  let from_ts = Int64.sub to_ts 300L in
  let deals =
    try recent_deals ~from_ts ~to_ts t
    with e ->
      Log.warn "[bcs poll] recent_deals failed: %s" (Printexc.to_string e);
      []
  in
  List.iter
    (fun (order_num, (exec : Broker_domain.Order.trade)) ->
      match placement_id_by_order_num t ~order_num with
      | None -> ()
      | Some placement_id ->
          let key =
            ( placement_id,
              exec.ts,
              Decimal.to_string exec.quantity,
              Decimal.to_string exec.price )
          in
          if Hashtbl.mem t.observed_deals key then ()
          else begin
            Hashtbl.replace t.observed_deals key ();
            let parent = try get_order t ~placement_id with _ -> None in
            let instrument =
              match parent with
              | Some o ->
                  (* Reverse from view model — for now use unknown
                     placeholder; future refactor surfaces domain
                     Instrument.t directly from the placement store. *)
                  let _ = o in
                  Core.Instrument.make
                    ~ticker:(Core.Ticker.of_string "UNKNOWN")
                    ~venue:(Core.Mic.of_string "MISX") ()
              | None ->
                  Core.Instrument.make
                    ~ticker:(Core.Ticker.of_string "UNKNOWN")
                    ~venue:(Core.Mic.of_string "MISX") ()
            in
            let side =
              match parent with
              | Some o -> ( try Side.of_string o.side with _ -> Side.Buy)
              | None -> Side.Buy
            in
            let new_total =
              Acl_common.Cumulative_sum.bump t.total_filled ~key:placement_id
                ~delta:exec.quantity
            in
            let trade_id =
              Printf.sprintf "%s:%Ld:%s" order_num exec.ts
                (Decimal.to_string exec.quantity)
            in
            let domain_ev : Broker_domain.Remote_broker.Events.Order_leg_filled.t =
              {
                placement_id;
                trade_id;
                instrument;
                side;
                fill_quantity = exec.quantity;
                fill_price = exec.price;
                fee = Decimal.zero;
                fill_ts = exec.ts;
                new_total_filled = new_total;
              }
            in
            dispatch t (Broker.Order_leg_filled domain_ev)
          end)
    deals

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  let cfg = Rest.cfg t.rest in
  let auth = Rest.auth t.rest in
  let bridge = Ws_bridge.make ~env ~sw ~cfg ~auth in
  t.bridge <- Some bridge;
  let poll_interval = 5 in
  Eio.Fiber.fork ~sw (fun () ->
      while true do
        (try poll_fills_once t ~env
         with e -> Log.warn "[bcs poll] tick failed: %s" (Printexc.to_string e));
        Eio.Time.sleep (Eio.Stdenv.clock env) (Float.of_int poll_interval)
      done)

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
            let on_candle
                (instrument : Instrument.t)
                (timeframe : Timeframe.t)
                (candle : Candle.t) =
              if
                Acl_common.Stream_dedup.should_accept t.bar_dedup
                  ~key:(instrument, timeframe) ~ts:candle.ts ~value:candle
              then
                dispatch t
                  (Broker.Remote_bar_updated
                     {
                       Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument;
                       timeframe;
                       candle;
                     })
            in
            try Ws_bridge.subscribe_bars bridge ~instrument ~timeframe ~on_candle
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
      let get_executions = get_executions
      let start_live_feed = start_live_feed
      let subscribe = subscribe
      let unsubscribe = unsubscribe
    end)
    t

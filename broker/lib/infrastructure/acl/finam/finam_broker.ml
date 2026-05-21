(** Adapter: exposes [Finam.Rest.t] through the broker-agnostic
    [Broker.S] interface. All Finam-specific translation lives here so
    callers (server, CLI, tests) program against [Broker.client].

    [account_id] is baked into the adapter at construction so the port
    stays account-agnostic (a Finam user with multiple accounts creates
    one [Broker.client] per account).

    {b Order identity at the port.} The placement-keyed methods
    speak [placement_id : int]. The adapter mints a Finam-format
    [client_order_id] (32 hex digits — Finam's validator rejects
    dashes) on submit and records [(placement_id ↦
    client_order_id)] in a private {!Placement_handle_store}.

    {b Order identity at venue.} Finam in turn addresses
    individual orders by its own server-assigned id, while
    [Rest.t] still speaks [client_order_id]. A second internal
    [client_order_id ↦ order_id] cache keeps the venue-side
    translation hot; cache misses fall back to scanning [GET
    /orders] so the mapping survives adapter restarts as long as
    Finam still holds the order.

    {b Live feeds.} The adapter owns the multiplexed WS bridge,
    the on_event dispatch, the per-(instrument, timeframe)
    subscription refcount, and the on-the-fly translation of
    raw WS frames into the port's {!Broker.event} variants.
    Callers initialise the machinery via {!start_live_feed} and
    add / remove per-key subscriptions via {!subscribe} /
    {!unsubscribe}. The account-wide trades subscription is
    always-on from the moment {!start_live_feed} is called. *)

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
  account_id : string;
  placements : Placement_handle_store.t;
  order_id_by_cid : (string, string) Hashtbl.t;
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
  mutex : Eio.Mutex.t;
  mutable bridge : Ws_bridge.bridge option;
  mutable on_event : (Broker.event -> unit) option;
  mutable bar_refcount : int SubMap.t;
}

let name = "finam"

let make ~account_id (rest : Rest.t) : t =
  {
    rest;
    account_id;
    placements = Placement_handle_store.create ();
    order_id_by_cid = Hashtbl.create 16;
    total_filled = Acl_common.Cumulative_sum.create ~zero:Decimal.zero ~add:Decimal.add;
    bar_dedup = Acl_common.Stream_dedup.create ~equal_value:Candle.equal;
    mutex = Eio.Mutex.create ();
    bridge = None;
    on_event = None;
    bar_refcount = SubMap.empty;
  }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe

(** Decode Finam's [/v1/exchanges] payload into MIC codes. We drop the
    [name] field — display labels are the UI's concern, not the
    adapter's. Any malformed MIC is silently filtered (Finam has shipped
    placeholder rows in the past). *)
let venues t : Mic.t list =
  let j = Rest.exchanges t.rest in
  match Yojson.Safe.Util.member "exchanges" j with
  | `List items ->
      List.filter_map
        (fun item ->
          match Yojson.Safe.Util.member "mic" item with
          | `String m -> ( try Some (Mic.of_string m) with Invalid_argument _ -> None)
          | _ -> None)
        items
  | _ -> []

let remember t ~client_order_id ~order_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.replace t.order_id_by_cid client_order_id order_id)

(** Reverse lookup [order_id → placement_id]. Two hops:
    [order_id → client_order_id] via the in-process
    [order_id_by_cid] cache, then
    [client_order_id → placement_id] via the placement store.
    Returns [None] when either link is unknown (e.g. a fill
    arrives for an order this adapter never placed, or its
    caches rotated out of memory). *)
let placement_id_by_order_id t ~order_id : int option =
  let cid_opt =
    Eio.Mutex.use_ro t.mutex (fun () ->
        Hashtbl.fold
          (fun cid oid acc ->
            match acc with
            | Some _ -> acc
            | None -> if String.equal oid order_id then Some cid else None)
          t.order_id_by_cid None)
  in
  match cid_opt with
  | None -> None
  | Some client_order_id ->
      Placement_handle_store.find_placement_id t.placements ~client_order_id

let account_id t = t.account_id

let resolve_order_id t ~client_order_id =
  let cached =
    Eio.Mutex.use_ro t.mutex (fun () ->
        Hashtbl.find_opt t.order_id_by_cid client_order_id)
  in
  match cached with
  | Some id -> id
  | None -> (
      let orders = Rest.get_orders t.rest ~account_id:t.account_id in
      match
        List.find_opt
          (fun (o : External_order.t) -> o.client_order_id = client_order_id)
          orders
      with
      | Some o ->
          remember t ~client_order_id ~order_id:o.order_id;
          o.order_id
      | None ->
          failwith
            (Printf.sprintf "finam: no order with client_order_id=%s" client_order_id))

(** UUID v4 with dashes stripped. Finam's REST validator returns
    400 on dashes ("letters, numbers and space" only), and 32 hex
    digits comfortably satisfy that rule while retaining full UUIDv4
    collision resistance. *)
let mint_client_order_id () =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  String.concat "" (String.split_on_char '-' uuid)

let project ~placement_id (v : External_order.t) : Order_view_model.t =
  Order_view_model.of_domain (External_order.to_broker_domain ~placement_id v)

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif :
    Order_view_model.t =
  let cid = mint_client_order_id () in
  (match
     Placement_handle_store.record t.placements ~placement_id ~client_order_id:cid
   with
  | `Ok | `Already_exists -> ());
  let external_order =
    Rest.place_order t.rest ~account_id:t.account_id ~instrument ~side ~quantity ~kind
      ~tif ~client_order_id:cid ()
  in
  remember t ~client_order_id:cid ~order_id:external_order.order_id;
  project ~placement_id external_order

let cancel_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order = Rest.cancel_order t.rest ~account_id:t.account_id ~order_id in
      Some (project ~placement_id external_order)

let get_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order = Rest.get_order t.rest ~account_id:t.account_id ~order_id in
      Some (project ~placement_id external_order)

let get_executions t ~placement_id : Execution_view_model.t list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      Rest.get_trades t.rest ~account_id:t.account_id
      |> List.filter_map (fun (at : Dto.account_trade) ->
          if at.order_id = order_id then Some (Execution_view_model.of_domain at.trade)
          else None)

let timeframes_for_instrument t instrument : Timeframe.t list =
  Eio.Mutex.use_ro t.mutex (fun () ->
      SubMap.fold
        (fun (i, tf) _ acc -> if Instrument.equal i instrument then tf :: acc else acc)
        t.bar_refcount [])

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event
      with e -> Log.warn "[finam] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Translate a parsed [Ws.event] into zero or more {!Broker.event}s
    and hand each to the registered [on_event] callback. Bars are
    fanned out across configured timeframes (when the wire payload
    lacks the timeframe — Finam's gRPC bridge sometimes drops it).
    Trades are resolved to their owning placement here; fills
    against unknown orders are dropped with a warn. *)
let dispatch_ws_event t (ev : Ws.event) : unit =
  match ev with
  | Bars b ->
      let tfs : Timeframe.t list =
        match b.timeframe with
        | Some tf -> [ tf ]
        | None -> timeframes_for_instrument t b.instrument
      in
      List.iter
        (fun (tf : Timeframe.t) ->
          List.iter
            (fun (candle : Candle.t) ->
              if
                Acl_common.Stream_dedup.should_accept t.bar_dedup ~key:(b.instrument, tf)
                  ~ts:candle.ts ~value:candle
              then
                dispatch t
                  (Broker.Remote_bar_updated
                     {
                       Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument =
                         b.instrument;
                       timeframe = tf;
                       candle;
                     }))
            b.bars)
        tfs
  | Trades trades ->
      List.iter
        (fun (tu : Ws.Events.Trade.update) ->
          match placement_id_by_order_id t ~order_id:tu.order_id with
          | None ->
              Log.warn "[finam ws] trade for unknown order_id=%s — skipping" tu.order_id
          | Some placement_id ->
              let new_total =
                Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                    Acl_common.Cumulative_sum.bump t.total_filled ~key:placement_id
                      ~delta:tu.quantity)
              in
              let domain_ev : Broker_domain.Remote_broker.Events.Order_leg_filled.t =
                {
                  placement_id;
                  trade_id = tu.trade_id;
                  instrument = tu.instrument;
                  side = tu.side;
                  fill_quantity = tu.quantity;
                  fill_price = tu.price;
                  fee = Decimal.zero;
                  fill_ts = tu.ts;
                  new_total_filled = new_total;
                }
              in
              dispatch t (Broker.Order_leg_filled domain_ev))
        trades
  | Error_ev e -> Ws.Events.Error_handler.handle e
  | Lifecycle ev -> Ws.Events.Lifecycle_handler.handle ev
  | Quote _ | Other _ -> ()

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  let cfg = Rest.cfg t.rest in
  let auth = Rest.auth t.rest in
  let bridge = Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event:(dispatch_ws_event t) in
  t.bridge <- Some bridge;
  (* Always-on personal-account trades subscription. Finam
     multiplexes it on the same socket as bars; we subscribe at
     init regardless of whether anyone has requested per-key
     bars yet. *)
  try Ws_bridge.subscribe_trades bridge ~account_id:t.account_id
  with e -> Log.warn "[finam ws] subscribe_trades failed: %s" (Printexc.to_string e)

let with_bridge t f =
  match t.bridge with
  | None -> Log.warn "[finam] subscribe/unsubscribe before start_live_feed — ignored"
  | Some bridge -> f bridge

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
            try Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
            with e ->
              Log.warn "[finam ws] subscribe_bars failed: %s" (Printexc.to_string e))

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
            try Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
            with e ->
              Log.warn "[finam ws] unsubscribe_bars failed: %s" (Printexc.to_string e))

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

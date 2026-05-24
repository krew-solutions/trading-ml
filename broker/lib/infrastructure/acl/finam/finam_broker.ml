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
  fill_dedup :
    (int, Broker_domain.Remote_broker.Events.Order_filled.t) Acl_common.Stream_dedup.t;
      (** Per-placement fill-stream deduplicator. Shared
          between the WS [Trades] branch and the REST
          [Rest.get_trades] fallback branch so the same fill
          never crosses the ACL boundary twice. Keyed by
          [placement_id]; [equal_value] compares [trade_id]
          since Finam exposes the per-leg id on both wire
          paths (BCS has to compromise on a partial
          discriminator because BCS REST has no equivalent
          field). *)
  mutex : Eio.Mutex.t;
  mutable bridge : Ws_bridge.bridge option;
  mutable on_event : (Broker.event -> unit) option;
  mutable bar_refcount : int SubMap.t;
  mutable bar_supervisors : Candle.t Acl_common.Transport_supervisor.t SubMap.t;
      (** Per-(instrument, timeframe) bar supervisor. One
          {!Acl_common.Transport_supervisor} per active bar
          subscription, each wired into the multiplexed WS
          bridge via [Ws_bridge.register_lifecycle] so a
          single WS disconnect fans across all of them. *)
  mutable bar_supervisor_listeners : (SubKey.t * Ws_bridge.listener_id) list;
      (** Tracks lifecycle-listener IDs so [unsubscribe] can
          [Ws_bridge.unregister_lifecycle] in addition to
          stopping the supervisor. *)
  mutable fill_supervisor :
    Broker_domain.Remote_broker.Events.Order_filled.t Acl_common.Transport_supervisor.t
    option;
      (** Account-wide fill supervisor — one per adapter
          instance. Created in {!start_live_feed} and bound to
          the adapter's lifetime; no explicit stop. *)
  mutable live_feed_ctx : (Eio.Switch.t * Eio_unix.Stdenv.base) option;
      (** [sw, env] captured at {!start_live_feed} so per-key
          bar supervisors created later by {!subscribe} run
          under the same switch as the bridge. None until
          start_live_feed has fired; subscribe before that is
          a programmer error (the broker is not live yet). *)
}

let name = "finam"

let make ~account_id (rest : Rest.t) : t =
  let fill_equal
      (a : Broker_domain.Remote_broker.Events.Order_filled.t)
      (b : Broker_domain.Remote_broker.Events.Order_filled.t) : bool =
    String.equal a.trade_id b.trade_id
  in
  {
    rest;
    account_id;
    placements = Placement_handle_store.create ();
    order_id_by_cid = Hashtbl.create 16;
    total_filled = Acl_common.Cumulative_sum.create ~zero:Decimal.zero ~add:Decimal.add;
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
          (fun (o : Dto.Order.t) -> o.client_order_id = client_order_id)
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

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif :
    Broker_domain.Order.t =
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
  Dto.Order.to_domain ~placement_id external_order

let cancel_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order = Rest.cancel_order t.rest ~account_id:t.account_id ~order_id in
      Some (Dto.Order.to_domain ~placement_id external_order)

let get_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order = Rest.get_order t.rest ~account_id:t.account_id ~order_id in
      Some (Dto.Order.to_domain ~placement_id external_order)

let get_trades t ~placement_id : Broker_domain.Order.trade list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      Rest.get_trades t.rest ~account_id:t.account_id
      |> List.filter_map (fun (at : Dto.Trade.t) ->
          if at.order_id = order_id then Some at.trade else None)

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event
      with e -> Log.warn "[finam] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Funnel one inbound WS trade into the fill supervisor.
    Returns a raw [Order_filled.t] with [new_total_filled =
    zero] — the supervisor's [emit] closure
    ({!finalize_and_dispatch_fill}) does the cumulative-bump
    post-dedup. Returns [None] when we don't recognise the
    [order_id] (a fill against some other client's order, or a
    fill that raced ahead of the [remember] write). *)
let order_filled_of_ws_trade t (tu : Ws.Events.Trade.update) :
    Broker_domain.Remote_broker.Events.Order_filled.t option =
  match placement_id_by_order_id t ~order_id:tu.order_id with
  | None ->
      Log.warn "[finam ws] trade for unknown order_id=%s — skipping" tu.order_id;
      None
  | Some placement_id ->
      Some (Ws.Events.Trade.to_domain ~placement_id ~new_total_filled:Decimal.zero tu)

(** Common seam between WS and REST branches of the fill
    supervisor: dedup happened upstream in the supervisor; here
    we bump the cumulative and dispatch. Mirrors BCS's
    [finalize_and_dispatch]. *)
let finalize_and_dispatch_fill t (raw : Broker_domain.Remote_broker.Events.Order_filled.t)
    : unit =
  let new_total_filled =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        Acl_common.Cumulative_sum.bump t.total_filled ~key:raw.placement_id
          ~delta:raw.fill_quantity)
  in
  dispatch t (Broker.Order_filled { raw with new_total_filled })

(** Translate a parsed [Ws.event] into zero or more {!Broker.event}s
    by routing them to the matching supervisor. Dedup is the
    supervisor's responsibility (it shares the same [Stream_dedup]
    instance as the REST-fallback poll branch). For fills, the
    cumulative bookkeeping happens inside the supervisor's [emit]
    via {!finalize_and_dispatch_fill}. *)
let dispatch_ws_event t (ev : Ws.event) : unit =
  match ev with
  | Bars b -> (
      let key = (b.instrument, b.timeframe) in
      match
        Eio.Mutex.use_ro t.mutex (fun () -> SubMap.find_opt key t.bar_supervisors)
      with
      | Some sup ->
          List.iter
            (fun candle -> Acl_common.Transport_supervisor.feed_ws sup candle)
            b.bars
      | None ->
          Log.info "[finam ws] bars for unregistered key %s/%s — dropping"
            (Instrument.to_qualified b.instrument)
            (Timeframe.to_string b.timeframe))
  | Trades trades -> (
      match t.fill_supervisor with
      | None -> Log.warn "[finam ws] trades arrived before fill_supervisor — dropping"
      | Some sup ->
          List.iter
            (fun tu ->
              match order_filled_of_ws_trade t tu with
              | Some raw -> Acl_common.Transport_supervisor.feed_ws sup raw
              | None -> ())
            trades)
  | Error_ev e -> Log.warn "[finam ws] error %d %s: %s" e.code e.type_ e.message
  | Lifecycle ev -> Log.info "[finam ws] %s (%d) %s" ev.event ev.code ev.reason
  | Quote _ | Other _ -> ()

(** REST-side branch of the fill supervisor's [poll_window].
    Pulls [account_trade]s for [(since_ts, to_ts)] and lifts
    each to a raw [Order_filled.t]. All discriminators —
    [trade_id], [instrument], [side] — come straight from the
    Finam wire payload (per the AccountTrade proto: symbol +
    side fields), so the REST branch produces structurally
    identical events to the WS branch and dedup on [trade_id]
    is exact. *)
let order_filled_of_rest_trade t (at : Dto.Trade.t) :
    Broker_domain.Remote_broker.Events.Order_filled.t option =
  match placement_id_by_order_id t ~order_id:at.order_id with
  | None -> None
  | Some placement_id ->
      Some
        {
          placement_id;
          trade_id = at.trade_id;
          instrument = at.instrument;
          side = at.side;
          fill_quantity = at.trade.quantity;
          fill_price = at.trade.price;
          fee = at.trade.fee;
          fill_ts = at.trade.ts;
          new_total_filled = Decimal.zero;
        }

let fill_poll_window t ~since_ts ~to_ts :
    Broker_domain.Remote_broker.Events.Order_filled.t list =
  try
    Rest.get_trades ~from_ts:since_ts ~to_ts t.rest ~account_id:t.account_id
    |> List.filter_map (order_filled_of_rest_trade t)
  with e ->
    Log.warn "[finam] fill poll failed: %s" (Printexc.to_string e);
    []

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  t.live_feed_ctx <- Some (sw, env);
  let cfg = Rest.cfg t.rest in
  let auth = Rest.auth t.rest in
  let bridge = Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event:(dispatch_ws_event t) in
  t.bridge <- Some bridge;
  let ts_now () = Int64.of_float (Unix.gettimeofday ()) in
  let dedup_accept (ev : Broker_domain.Remote_broker.Events.Order_filled.t) =
    Acl_common.Stream_dedup.should_accept t.fill_dedup ~key:ev.placement_id ~ts:ev.fill_ts
      ~value:ev
  in
  let sup =
    Acl_common.Transport_supervisor.start ~env ~sw ~label:"finam fills" ~poll_interval:5.0
      ~ts_now
      ~poll_window:(fun ~since_ts ~to_ts -> fill_poll_window t ~since_ts ~to_ts)
      ~ts_of_event:(fun ev -> ev.Broker_domain.Remote_broker.Events.Order_filled.fill_ts)
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
  (* Always-on personal-account trades subscription. Finam
     multiplexes it on the same socket as bars; we subscribe at
     init regardless of whether anyone has requested per-key
     bars yet. WS-success is signalled to the supervisor only
     when subscribe_trades returns without raising. *)
  try
    Ws_bridge.subscribe_trades bridge ~account_id:t.account_id;
    Acl_common.Transport_supervisor.ws_came_up sup
  with e -> Log.warn "[finam ws] subscribe_trades failed: %s" (Printexc.to_string e)

let with_bridge t f =
  match t.bridge with
  | None -> Log.warn "[finam] subscribe/unsubscribe before start_live_feed — ignored"
  | Some bridge -> f bridge

(** Build the per-(instrument, timeframe) bar supervisor and wire
    it into the bridge's lifecycle-listener registry, returning
    the supervisor + the listener id for later teardown. *)
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
      Log.warn "[finam] bars poll %s/%s failed: %s"
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
    Printf.sprintf "finam bars %s/%s"
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
                Log.warn "[finam] subscribe_bars before start_live_feed ctx — ignored"
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
                  Log.warn "[finam ws] subscribe_bars failed: %s" (Printexc.to_string e)))

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
      let get_trades = get_trades
      let start_live_feed = start_live_feed
      let subscribe = subscribe
      let unsubscribe = unsubscribe
    end)
    t

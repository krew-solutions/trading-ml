(** Adapter: exposes the Finam gRPC {!Client.t} through the broker-agnostic
    {!Broker.S} interface. The gRPC counterpart of [Finam.Finam_broker]: same
    domain-facing contract and order-identity discipline, but every transport
    concern is gRPC — unary RPCs for orders/bars/venues/trade-history, and
    native server-streams for the live feed (bars, public tape, own fills),
    each kept alive by a {!Stream_runner}.

    {b Order identity at the port.} Placement-keyed methods speak
    [placement_id : int]. On submit the adapter mints a Finam-format
    [client_order_id] (32 hex digits — Finam's validator rejects dashes) and
    records [(placement_id ↦ client_order_id)] in a private
    {!Placement_handle_store}.

    {b Order identity at venue.} Finam addresses orders by its own server-side
    [order_id]; a second [client_order_id ↦ order_id] cache keeps that hot, with
    a [GetOrders] scan fallback so the mapping survives as long as Finam still
    holds the order.

    {b Live feed.} Native gRPC streams. The account-wide own-fills stream is
    always-on from {!start_live_feed}; per-[(instrument, timeframe)] bar streams
    and per-instrument public-tape streams are reference-counted and started /
    stopped by {!subscribe} / {!unsubscribe}. Dedup (bars by
    [(instrument, timeframe)], fills by [placement_id], tape by wire
    [trade_id]) suppresses any prefix replayed when a stream re-subscribes. *)

open Core
module Sd = Acl_common.Stream_dedup
module Stream_runner = Grpc_client.Stream_runner

module SubKey = struct
  type t = Instrument.t * Timeframe.t

  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)
module InstrMap = Map.Make (Instrument)

type t = {
  client : Client.t;
  account_id : string;
  placements : Placement_handle_store.t;
  order_id_by_cid : (string, string) Hashtbl.t;
  bar_dedup : (SubKey.t, Candle.t) Sd.t;
  fill_dedup : (int, Broker_domain.Remote_broker.Events.Trade_executed.t) Sd.t;
  mutex : Eio.Mutex.t;
  mutable on_event : (Broker.event -> unit) option;
  mutable live_ctx : (Eio.Switch.t * Eio_unix.Stdenv.base) option;
  mutable fills_runner : Stream_runner.t option;
  mutable bar_refcount : int SubMap.t;
  mutable bar_runners : Stream_runner.t SubMap.t;
  mutable tape_refcount : int InstrMap.t;
  mutable tape_runners : Stream_runner.t InstrMap.t;
}

let name = "finam-grpc"

let make ~account_id (client : Client.t) : t =
  let fill_equal
      (a : Broker_domain.Remote_broker.Events.Trade_executed.t)
      (b : Broker_domain.Remote_broker.Events.Trade_executed.t) : bool =
    String.equal a.trade_id b.trade_id
  in
  {
    client;
    account_id;
    placements = Placement_handle_store.create ();
    order_id_by_cid = Hashtbl.create 16;
    bar_dedup = Sd.create ~equal_value:Candle.equal;
    fill_dedup = Sd.create ~equal_value:fill_equal;
    mutex = Eio.Mutex.create ();
    on_event = None;
    live_ctx = None;
    fills_runner = None;
    bar_refcount = SubMap.empty;
    bar_runners = SubMap.empty;
    tape_refcount = InstrMap.empty;
    tape_runners = InstrMap.empty;
  }

let account_id t = t.account_id

(* ---- order-identity caches -------------------------------------------- *)

let remember t ~client_order_id ~order_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.replace t.order_id_by_cid client_order_id order_id)

(** Reverse lookup [order_id → placement_id]: [order_id → client_order_id] via
    the in-process cache, then [client_order_id → placement_id] via the store.
    [None] when either link is unknown (a fill for an order this adapter never
    placed, or a cache that rotated out). *)
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
  | Some cid -> Placement_handle_store.find_placement_id t.placements ~client_order_id:cid

(** Resolve [client_order_id → order_id]; cache miss falls back to a [GetOrders]
    scan so the mapping survives adapter restarts while Finam holds the order. *)
let resolve_order_id t ~client_order_id =
  let cached =
    Eio.Mutex.use_ro t.mutex (fun () ->
        Hashtbl.find_opt t.order_id_by_cid client_order_id)
  in
  match cached with
  | Some id -> id
  | None -> (
      let orders = Client.get_orders t.client ~account_id:t.account_id in
      match
        List.find_opt
          (fun (o : Order_dto.t) -> o.client_order_id = client_order_id)
          orders
      with
      | Some o ->
          remember t ~client_order_id ~order_id:o.order_id;
          o.order_id
      | None ->
          failwith
            (Printf.sprintf "finam-grpc: no order with client_order_id=%s" client_order_id)
      )

(** UUID v4, dashes stripped, truncated to 20 hex chars. The Finam gRPC
    [Order.client_order_id] is capped at 20 characters (verified live: a longer
    id is rejected with INVALID_ARGUMENT) — narrower than the REST sibling, whose
    validator only constrains the charset. 20 hex digits keep 80 bits of
    entropy, ample collision resistance for in-flight orders. *)
let mint_client_order_id () =
  Uuidm.v4_gen (Random.State.make_self_init ()) ()
  |> Uuidm.to_string |> String.split_on_char '-' |> String.concat ""
  |> fun s -> String.sub s 0 20

(* ---- unary port methods ----------------------------------------------- *)

let bars t ~n ~instrument ~timeframe = Client.bars t.client ~n ~instrument ~timeframe
let venues t : Mic.t list = Client.exchanges t.client

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif :
    Broker_domain.Order.t =
  let cid = mint_client_order_id () in
  (match
     Placement_handle_store.record t.placements ~placement_id ~client_order_id:cid
   with
  | `Ok | `Already_exists -> ());
  let ext =
    Client.place_order t.client ~account_id:t.account_id ~instrument ~side ~quantity ~kind
      ~tif ~client_order_id:cid
  in
  remember t ~client_order_id:cid ~order_id:ext.order_id;
  Order_dto.to_domain ~placement_id ext

let cancel_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let ext = Client.cancel_order t.client ~account_id:t.account_id ~order_id in
      Some (Order_dto.to_domain ~placement_id ext)

let get_order t ~placement_id : Broker_domain.Order.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let ext = Client.get_order t.client ~account_id:t.account_id ~order_id in
      Some (Order_dto.to_domain ~placement_id ext)

let get_trades t ~placement_id : Broker_domain.Order.Trade.t list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      Client.account_trades t.client ~account_id:t.account_id
      |> List.filter_map (fun (at : Conv.Pb_account_trade.t) ->
          if at.order_id = order_id then Some (Conv.order_trade_of_account at) else None)

(* ---- event dispatch ---------------------------------------------------- *)

let dispatch t (event : Broker.event) : unit =
  match t.on_event with
  | Some f -> (
      try f event
      with e -> Log.warn "[finam-grpc] on_event raised: %s" (Printexc.to_string e))
  | None -> ()

(** Funnel one streamed own-fill: resolve its [placement_id], dedup by it, emit.
    Fills for unrecognised orders (foreign, or racing the [remember] write) are
    dropped. *)
let handle_fill t (at : Conv.Pb_account_trade.t) : unit =
  match placement_id_by_order_id t ~order_id:at.order_id with
  | None -> Log.info "[finam-grpc] fill for unknown order_id=%s — skipping" at.order_id
  | Some placement_id ->
      let ev = Conv.trade_executed_of_account ~placement_id at in
      if Sd.should_accept t.fill_dedup ~key:placement_id ~ts:ev.ts ~value:ev then
        dispatch t (Broker.Trade_executed ev)

(** Funnel one streamed bar: dedup by [(instrument, timeframe)], emit. *)
let handle_bar t ~instrument ~timeframe (candle : Candle.t) : unit =
  if Sd.should_accept t.bar_dedup ~key:(instrument, timeframe) ~ts:candle.ts ~value:candle
  then
    dispatch t
      (Broker.Bar_updated
         { Broker_domain.Remote_broker.Events.Bar_updated.instrument; timeframe; candle })

(** Public-tape handler with [trade_id] high-water dedup, persistent across
    re-subscribes (the ref is created once per subscription, not per stream
    attempt). Non-numeric ids cannot be high-watered, so they pass through. *)
let make_tape_handler t ~instrument =
  let high_water = ref None in
  fun (tr : Conv.Md.Trade.t) ->
    let id = Int64.of_string_opt tr.trade_id in
    let fresh =
      match (id, !high_water) with
      | Some i, Some hw -> Int64.compare i hw > 0
      | Some _, None | None, _ -> true
    in
    if fresh then begin
      (match id with
      | Some i ->
          high_water :=
            Some
              (match !high_water with
              | Some hw -> Int64.max hw i
              | None -> i)
      | None -> ());
      dispatch t (Broker.Public_trade_printed (Conv.public_trade_of_md ~instrument tr))
    end

(* ---- live feed --------------------------------------------------------- *)

let start_live_feed t ~sw ~env ~on_event : unit =
  t.on_event <- Some on_event;
  t.live_ctx <- Some (sw, env);
  (* The gRPC channel's HTTP/2 fiber lives under the host switch; bind it here,
     before any unary call or stream is issued. *)
  Client.set_switch t.client sw;
  (* Always-on own-fills stream, account-wide. *)
  let run () =
    Client.subscribe_trades t.client ~account_id:t.account_id ~on_trade:(handle_fill t)
  in
  t.fills_runner <- Some (Stream_runner.start ~sw ~env ~label:"fills" ~run ())

let subscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } -> (
      let key = (instrument, timeframe) in
      let should_start =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            let prev = Option.value ~default:0 (SubMap.find_opt key t.bar_refcount) in
            t.bar_refcount <- SubMap.add key (prev + 1) t.bar_refcount;
            prev = 0)
      in
      if should_start then
        match t.live_ctx with
        | None -> Log.warn "[finam-grpc] subscribe_bars before start_live_feed — ignored"
        | Some (sw, env) ->
            let run () =
              Client.subscribe_bars t.client ~instrument ~timeframe
                ~on_bar:(handle_bar t ~instrument ~timeframe)
            in
            let label =
              Printf.sprintf "bars %s/%s"
                (Instrument.to_qualified instrument)
                (Timeframe.to_string timeframe)
            in
            let r = Stream_runner.start ~sw ~env ~label ~run () in
            Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                t.bar_runners <- SubMap.add key r t.bar_runners))
  | Subscribe_public_trades { instrument } -> (
      let should_start =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            let prev =
              Option.value ~default:0 (InstrMap.find_opt instrument t.tape_refcount)
            in
            t.tape_refcount <- InstrMap.add instrument (prev + 1) t.tape_refcount;
            prev = 0)
      in
      if should_start then
        match t.live_ctx with
        | None ->
            Log.warn
              "[finam-grpc] subscribe_public_trades before start_live_feed — ignored"
        | Some (sw, env) ->
            let on_trade = make_tape_handler t ~instrument in
            let run () = Client.subscribe_latest_trades t.client ~instrument ~on_trade in
            let label = Printf.sprintf "tape %s" (Instrument.to_qualified instrument) in
            let r = Stream_runner.start ~sw ~env ~label ~run () in
            Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                t.tape_runners <- InstrMap.add instrument r t.tape_runners))

let unsubscribe t (request : Broker.request) : unit =
  match request with
  | Subscribe_bars { instrument; timeframe } ->
      let key = (instrument, timeframe) in
      let runner =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            match SubMap.find_opt key t.bar_refcount with
            | None | Some 0 -> None
            | Some 1 ->
                t.bar_refcount <- SubMap.remove key t.bar_refcount;
                let r = SubMap.find_opt key t.bar_runners in
                t.bar_runners <- SubMap.remove key t.bar_runners;
                r
            | Some n ->
                t.bar_refcount <- SubMap.add key (n - 1) t.bar_refcount;
                None)
      in
      Option.iter Stream_runner.stop runner
  | Subscribe_public_trades { instrument } ->
      let runner =
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
            match InstrMap.find_opt instrument t.tape_refcount with
            | None | Some 0 -> None
            | Some 1 ->
                t.tape_refcount <- InstrMap.remove instrument t.tape_refcount;
                let r = InstrMap.find_opt instrument t.tape_runners in
                t.tape_runners <- InstrMap.remove instrument t.tape_runners;
                r
            | Some n ->
                t.tape_refcount <- InstrMap.add instrument (n - 1) t.tape_refcount;
                None)
      in
      Option.iter Stream_runner.stop runner

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

let _ = account_id

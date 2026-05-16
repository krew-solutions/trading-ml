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
    on create_order, every order is effectively DAY. *)

open Core

type t = { rest : Rest.t; placements : Placement_handle_store.t }

let name = "bcs"

let make (rest : Rest.t) : t = { rest; placements = Placement_handle_store.create () }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe

let venues _t : Mic.t list = [ Mic.of_string "MISX" ]

(** UUIDv4 in canonical dashed form — BCS validates [clientOrderId]
    as "UUID format" and 400s on anything else. *)
let mint_client_order_id () =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let place_order_by_placement_id t ~placement_id ~instrument ~side ~quantity ~kind ~tif:_ :
    Order_view_model.t =
  let cid = mint_client_order_id () in
  (match
     Placement_handle_store.record t.placements ~placement_id ~client_order_id:cid
   with
  | `Ok | `Already_exists -> ());
  let q_int = int_of_float (Decimal.to_float quantity) in
  let order =
    Rest.create_order t.rest ~instrument ~side ~quantity:q_int ~kind ~client_order_id:cid
      ()
  in
  Order_view_model.of_domain ~placement_id order

let cancel_order_by_placement_id t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order = Rest.cancel_order t.rest ~client_order_id:cid in
      Some (Order_view_model.of_domain ~placement_id order)

let get_order_by_placement_id t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order = Rest.get_order t.rest ~client_order_id:cid in
      Some (Order_view_model.of_domain ~placement_id order)

(** Project account-wide deals into per-execution records for the
    placement identified by [placement_id]. BCS's deal payload
    does not carry [clientOrderId] — only [orderNum]
    (broker-assigned). So we resolve the order first to pick up
    its [exec_id] (= the [orderNum] kept on [Order.t]), then
    filter the deals list by string-equality on that id.
    Returns [] if the placement is unknown, has no [exec_id] yet
    (still pending), or no fills against it. *)
let get_executions_by_placement_id t ~placement_id : Execution_view_model.t list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let order = Rest.get_order t.rest ~client_order_id:cid in
      if order.exec_id = "" then []
      else
        Rest.get_deals t.rest
        |> List.filter_map (fun (order_num, exec) ->
            if order_num = order.exec_id then Some (Execution_view_model.of_domain exec)
            else None)

let as_broker (rest : Rest.t) : Broker.client =
  let t = make rest in
  Broker.make
    (module struct
      type nonrec t = t

      let name = name
      let bars = bars
      let venues = venues
      let place_order_by_placement_id = place_order_by_placement_id
      let cancel_order_by_placement_id = cancel_order_by_placement_id
      let get_order_by_placement_id = get_order_by_placement_id
      let get_executions_by_placement_id = get_executions_by_placement_id
    end)
    t

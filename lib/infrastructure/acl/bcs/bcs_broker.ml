(** Adapter from [Bcs.Rest.t] to [Broker.S]. Symmetric to
    [Finam_broker]: returns the venues this broker can route to as MIC
    codes. BCS-via-QUIK is MOEX-only in our setup, so this is a single
    static MIC; the per-board distinction (TQBR/SPBFUT/...) lives on
    the {!Instrument.t} as [board], not here.

    Order identity: BCS uses the caller-supplied [clientOrderId] as the
    server-side id too, so the port's [client_order_id] key maps 1:1
    with no extra bookkeeping (unlike Finam which issues its own id).

    Quantity conversion: the port speaks [Decimal.t] for uniformity,
    but BCS's REST wire format wants a plain integer (MOEX equities
    trade in integer lots). We truncate via float — precision is
    adequate for lot-sized quantities.

    Time-in-force is silently ignored: BCS doesn't expose a TIF field
    on create_order, every order is effectively DAY. *)

open Core

type t = Rest.t

let name = "bcs"

let bars t ~n ~instrument ~timeframe = Rest.bars t ~n ~instrument ~timeframe

let venues _t : Mic.t list = [ Mic.of_string "MISX" ]

let place_order t ~instrument ~side ~quantity ~kind ~tif:_ ~client_order_id =
  let q_int = int_of_float (Decimal.to_float quantity) in
  Rest.create_order t ~instrument ~side ~quantity:q_int ~kind ~client_order_id ()

let get_orders t = Rest.get_orders t
let get_order t ~client_order_id = Rest.get_order t ~client_order_id
let cancel_order t ~client_order_id = Rest.cancel_order t ~client_order_id

(** Project account-wide deals into per-execution records for the
    order identified by [client_order_id]. BCS's deal payload does
    not carry [clientOrderId] — only [orderNum] (broker-assigned).
    So we resolve the order first to pick up its [exec_id] (= the
    [orderNum] kept on [Order.t]), then filter the deals list by
    string-equality on that id. Returns [] if the order has no
    [exec_id] yet (still pending) or no fills against it.

    Unverified against a live account — per-call [get_order] is
    an extra HTTP roundtrip; a cid→exec_id cache (like Finam's)
    is the obvious follow-up once we see volume. *)
let get_executions t ~client_order_id =
  let order = Rest.get_order t ~client_order_id in
  if order.exec_id = "" then []
  else
    Rest.get_deals t
    |> List.filter_map (fun (order_num, exec) ->
        if order_num = order.exec_id then Some exec else None)

(** UUIDv4 in canonical dashed form — BCS validates [clientOrderId]
    as "UUID format" and 400s on anything else. *)
let generate_client_order_id _ =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let as_broker (rest : Rest.t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t
      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let get_orders = get_orders
      let get_order = get_order
      let cancel_order = cancel_order
      let get_executions = get_executions
      let generate_client_order_id = generate_client_order_id
    end)
    rest

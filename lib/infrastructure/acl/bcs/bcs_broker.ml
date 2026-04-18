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

let bars t ~n ~instrument ~timeframe =
  Rest.bars t ~n ~instrument ~timeframe

let venues _t : Mic.t list = [ Mic.of_string "MISX" ]

let place_order t ~instrument ~side ~quantity ~kind ~tif:_ ~client_order_id =
  let q_int = int_of_float (Decimal.to_float quantity) in
  Rest.create_order t ~instrument ~side ~quantity:q_int
    ~kind ~client_order_id ()

let get_orders t = Rest.get_orders t
let get_order t ~client_order_id = Rest.get_order t ~client_order_id
let cancel_order t ~client_order_id = Rest.cancel_order t ~client_order_id

(** TODO: wire up the Deals endpoint once [Rest.get_deals] exists.
    BCS exposes [averagePrice] on [OrderStatus] directly (simpler
    shape than Finam), but for identical semantics across brokers
    we project per-execution [Deal] records into
    {!Order.execution}. Left as failwith until the Rest helper
    lands. *)
let get_executions _ ~client_order_id:_ =
  failwith "Bcs.Bcs_broker.get_executions: not yet implemented \
            (pending deals-list integration)"

let as_broker (rest : Rest.t) : Broker.client =
  Broker.make (module struct
    type nonrec t = t
    let name = name
    let bars = bars
    let venues = venues
    let place_order = place_order
    let get_orders = get_orders
    let get_order = get_order
    let cancel_order = cancel_order
    let get_executions = get_executions
  end) rest

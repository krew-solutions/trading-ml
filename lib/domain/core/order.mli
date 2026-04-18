(** Order model. Pure domain types and business predicates.
    Wire-format encoding (broker-specific enums) is the ACL's concern. *)

type kind =
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

type time_in_force = GTC | DAY | IOC | FOK

type status =
  | New
  | Partially_filled
  | Filled
  | Cancelled
  | Rejected
  | Expired
  | Pending_cancel
  | Pending_new
  | Suspended
  | Failed

type t = {
  id : string;
  exec_id : string;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  remaining : Decimal.t;
  kind : kind;
  tif : time_in_force;
  status : status;
  created_ts : int64;
  client_order_id : string;
}

(** One execution (trade / fill slice) reported by the broker.
    A single {!t} may be filled across multiple executions —
    {!Broker.S.get_executions} returns the list that sums to the
    order's [filled] quantity. Price and fee are per-execution
    (broker's actual numbers), not intended. *)
type execution = {
  ts : int64;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

val remaining_qty : t -> Decimal.t
val is_done : t -> bool

val kind_to_string : kind -> string
val status_to_string : status -> string
val tif_to_string : time_in_force -> string

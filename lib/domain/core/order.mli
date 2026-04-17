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

val remaining_qty : t -> Decimal.t
val is_done : t -> bool

val kind_to_string : kind -> string
val status_to_string : status -> string
val tif_to_string : time_in_force -> string

(** Order model. Maps to Finam Trade order types. *)

type kind =
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

type time_in_force = GTC | DAY | IOC | FOK

type status =
  | New | Partially_filled | Filled | Cancelled | Rejected | Expired

type t = {
  id : string;
  symbol : Symbol.t;
  side : Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : kind;
  tif : time_in_force;
  status : status;
  created_ts : int64;
}

let remaining o = Decimal.sub o.quantity o.filled

let is_done o =
  match o.status with
  | Filled | Cancelled | Rejected | Expired -> true
  | New | Partially_filled -> false

let kind_to_string = function
  | Market -> "MARKET"
  | Limit _ -> "LIMIT"
  | Stop _ -> "STOP"
  | Stop_limit _ -> "STOP_LIMIT"

let status_to_string = function
  | New -> "NEW" | Partially_filled -> "PARTIALLY_FILLED"
  | Filled -> "FILLED" | Cancelled -> "CANCELLED"
  | Rejected -> "REJECTED" | Expired -> "EXPIRED"

let tif_to_string = function
  | GTC -> "GTC" | DAY -> "DAY" | IOC -> "IOC" | FOK -> "FOK"

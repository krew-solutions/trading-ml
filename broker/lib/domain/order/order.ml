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
  placement_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : kind;
  tif : time_in_force;
  status : status;
  placed_ts : int64;
}

type trade = { ts : int64; quantity : Decimal.t; price : Decimal.t; fee : Decimal.t }

let remaining_qty (o : t) = Decimal.sub o.quantity o.filled

let is_done (o : t) =
  match o.status with
  | Filled | Cancelled | Rejected | Expired | Failed -> true
  | New | Partially_filled | Pending_cancel | Pending_new | Suspended -> false

let kind_to_string = function
  | Market -> "MARKET"
  | Limit _ -> "LIMIT"
  | Stop _ -> "STOP"
  | Stop_limit _ -> "STOP_LIMIT"

let status_to_string = function
  | New -> "NEW"
  | Partially_filled -> "PARTIALLY_FILLED"
  | Filled -> "FILLED"
  | Cancelled -> "CANCELLED"
  | Rejected -> "REJECTED"
  | Expired -> "EXPIRED"
  | Pending_cancel -> "PENDING_CANCEL"
  | Pending_new -> "PENDING_NEW"
  | Suspended -> "SUSPENDED"
  | Failed -> "FAILED"

let tif_to_string = function
  | GTC -> "GTC"
  | DAY -> "DAY"
  | IOC -> "IOC"
  | FOK -> "FOK"

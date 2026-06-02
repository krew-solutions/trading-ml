open Core

type t = Time of Timeframe.t | Volume of Decimal.t

let admits_time_close = function
  | Time _ -> true
  | Volume _ -> false

let period_seconds = function
  | Time tf -> Timeframe.to_seconds tf
  | Volume _ -> invalid_arg "Bar_boundary.period_seconds: Volume boundary has no period"

let bucket_start b ~ts =
  match b with
  | Time tf ->
      let period = Int64.of_int (Timeframe.to_seconds tf) in
      Int64.sub ts (Int64.rem ts period)
  | Volume _ ->
      invalid_arg "Bar_boundary.bucket_start: Volume boundary has no time bucket"

let vol_prefix = "VOL:"

let to_token = function
  | Time tf -> Timeframe.to_string tf
  | Volume cap -> vol_prefix ^ Decimal.to_string cap

let of_token s =
  let plen = String.length vol_prefix in
  if String.length s > plen && String.sub s 0 plen = vol_prefix then
    let cap = String.sub s plen (String.length s - plen) in
    match Decimal.of_string cap with
    | d -> Volume d
    | exception _ -> invalid_arg (Printf.sprintf "Bar_boundary.of_token: %S" s)
  else
    match Timeframe.of_string s with
    | tf -> Time tf
    | exception Invalid_argument _ ->
        invalid_arg (Printf.sprintf "Bar_boundary.of_token: %S" s)

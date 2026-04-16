(** Deterministic synthetic candle generator — used by the demo server
    when a live Finam token is not configured. Produces a random-walk
    stream with realistic intrabar structure. *)

open Core

let generate ~n ~start_ts ~tf_seconds ~start_price =
  let rng = Random.State.make [| 42; n |] in
  let rec loop i acc price ts =
    if i = n then List.rev acc
    else
      let drift = (Random.State.float rng 2.0 -. 1.0) *. 0.5 in
      let close = price +. drift in
      let close = Float.max 1.0 close in
      let high = Float.max price close +. Random.State.float rng 0.5 in
      let low = Float.min price close -. Random.State.float rng 0.5 in
      let low = Float.max 0.5 low in
      let volume = 100.0 +. Random.State.float rng 1000.0 in
      let c = Candle.make
        ~ts ~open_:(Decimal.of_float price)
        ~high:(Decimal.of_float high) ~low:(Decimal.of_float low)
        ~close:(Decimal.of_float close) ~volume:(Decimal.of_float volume)
      in
      loop (i + 1) (c :: acc) close (Int64.add ts (Int64.of_int tf_seconds))
  in
  loop 0 [] start_price start_ts

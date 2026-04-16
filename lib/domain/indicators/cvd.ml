(** Cumulative Volume Delta.
    Per-bar delta is estimated from the close's position within the range,
    since bar data carries no true bid/ask split:
      delta_t = volume · (2·close - high - low) / (high - low)
    giving +volume when close sits at the high, -volume at the low, 0 at
    the midpoint. CVD is the running sum of these deltas. For zero-range
    bars the delta is defined as 0 to avoid division by zero. *)

open Core

module M : Indicator.S = struct
  type state = { value : float; seeded : bool }
  type output = float

  let name = "CVD"

  let init () = { value = 0.0; seeded = false }

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let vol = Decimal.to_float c.volume in
    let range = high -. low in
    let delta =
      if range = 0.0 then 0.0
      else vol *. (2.0 *. close -. high -. low) /. range
    in
    let v = st.value +. delta in
    { value = v; seeded = true }, Some v

  let value st = if st.seeded then Some st.value else None
  let output_to_float x = [x]
end

let make () = Indicator.make (module M)

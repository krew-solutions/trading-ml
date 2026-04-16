(** Accumulation / Distribution Line (Williams).
    mfm_t = ((close - low) - (high - close)) / (high - low), 0 if range=0
    mfv_t = mfm_t · volume_t
    A/D_t = Σ mfv up to t — a running sum. *)

open Core

module M : Indicator.S = struct
  type state = { value : float; seeded : bool }
  type output = float

  let name = "A/D"

  let init () = { value = 0.0; seeded = false }

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let vol = Decimal.to_float c.volume in
    let range = high -. low in
    let mfm = if range = 0.0 then 0.0
              else ((close -. low) -. (high -. close)) /. range in
    let v = st.value +. mfm *. vol in
    { value = v; seeded = true }, Some v

  let value st = if st.seeded then Some st.value else None
  let output_to_float x = [x]
end

let make () = Indicator.make (module M)

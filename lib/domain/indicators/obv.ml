(** On-Balance Volume.
    OBV_0 = 0. For t > 0:
      close_t > close_{t-1} → OBV_t = OBV_{t-1} + volume_t
      close_t < close_{t-1} → OBV_t = OBV_{t-1} - volume_t
      otherwise             → OBV_t = OBV_{t-1} *)

open Core

module M : Indicator.S = struct
  type state = {
    prev_close : float option;
    value : float;
    seeded : bool;
  }
  type output = float

  let name = "OBV"

  let init () = { prev_close = None; value = 0.0; seeded = false }

  let update st c =
    let close = Decimal.to_float c.Candle.close in
    let vol = Decimal.to_float c.volume in
    let value' =
      match st.prev_close with
      | None -> st.value
      | Some prev ->
        if close > prev then st.value +. vol
        else if close < prev then st.value -. vol
        else st.value
    in
    let st' = { prev_close = Some close; value = value'; seeded = true } in
    st', Some value'

  let value st = if st.seeded then Some st.value else None
  let output_to_float x = [x]
end

let make () = Indicator.make (module M)

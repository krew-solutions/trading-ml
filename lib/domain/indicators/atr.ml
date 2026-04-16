(** Average True Range (Wilder).
    TR_t = max(high - low, |high - prev_close|, |low - prev_close|).
    ATR_t = ((n-1) * ATR_{t-1} + TR_t) / n, seeded by mean of first n TRs. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "ATR: period must be > 0"

  type state = {
    prev_close : float option;
    samples : int;
    seed_sum : float;
    value : float option;
  }
  type output = float

  let name = Printf.sprintf "ATR(%d)" C.period
  let n = float_of_int C.period

  let init () =
    { prev_close = None; samples = 0; seed_sum = 0.0; value = None }

  let true_range ~high ~low ~prev_close =
    let a = high -. low in
    let b = Float.abs (high -. prev_close) in
    let c = Float.abs (low -. prev_close) in
    Float.max a (Float.max b c)

  let update st candle =
    let high = Decimal.to_float candle.Candle.high in
    let low  = Decimal.to_float candle.Candle.low in
    let close = Decimal.to_float candle.Candle.close in
    match st.prev_close with
    | None -> { st with prev_close = Some close }, None
    | Some pc ->
      let tr = true_range ~high ~low ~prev_close:pc in
      if st.samples < C.period then
        let samples = st.samples + 1 in
        let seed_sum = st.seed_sum +. tr in
        if samples = C.period then
          let v = seed_sum /. n in
          { prev_close = Some close; samples; seed_sum;
            value = Some v }, Some v
        else
          { st with prev_close = Some close; samples; seed_sum }, None
      else
        let v = match st.value with Some v -> v | None -> tr in
        let v' = (v *. (n -. 1.0) +. tr) /. n in
        { st with prev_close = Some close; value = Some v' }, Some v'

  let value st = st.value
  let output_to_float x = [x]
end

let make ~period =
  let module M = Make (struct let period = period end) in
  Indicator.make (module M)

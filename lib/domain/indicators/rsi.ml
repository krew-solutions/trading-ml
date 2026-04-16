(** Relative Strength Index (Wilder).
    RSI = 100 - 100 / (1 + RS), where RS = avg_gain / avg_loss.
    Wilder smoothing: avg_t = ((n-1)·avg_{t-1} + x_t) / n. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 1 then invalid_arg "RSI: period must be > 1"

  type state = {
    prev_close : float option;
    samples : int;
    sum_gain : float;
    sum_loss : float;
    avg_gain : float;
    avg_loss : float;
    value : float option;
  }
  type output = float

  let n = float_of_int C.period
  let name = Printf.sprintf "RSI(%d)" C.period

  let init () = {
    prev_close = None; samples = 0;
    sum_gain = 0.0; sum_loss = 0.0;
    avg_gain = 0.0; avg_loss = 0.0;
    value = None;
  }

  let compute avg_g avg_l =
    if avg_l = 0.0 then 100.0
    else
      let rs = avg_g /. avg_l in
      100.0 -. (100.0 /. (1.0 +. rs))

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    match st.prev_close with
    | None ->
      { st with prev_close = Some price }, None
    | Some prev ->
      let diff = price -. prev in
      let gain = if diff > 0.0 then diff else 0.0 in
      let loss = if diff < 0.0 then -. diff else 0.0 in
      if st.samples < C.period then
        let samples = st.samples + 1 in
        let sum_gain = st.sum_gain +. gain in
        let sum_loss = st.sum_loss +. loss in
        if samples = C.period then
          let ag = sum_gain /. n in
          let al = sum_loss /. n in
          let v = compute ag al in
          { prev_close = Some price; samples;
            sum_gain; sum_loss;
            avg_gain = ag; avg_loss = al; value = Some v }, Some v
        else
          { st with prev_close = Some price; samples; sum_gain; sum_loss }, None
      else
        let ag = (st.avg_gain *. (n -. 1.0) +. gain) /. n in
        let al = (st.avg_loss *. (n -. 1.0) +. loss) /. n in
        let v = compute ag al in
        { st with prev_close = Some price;
                  avg_gain = ag; avg_loss = al; value = Some v }, Some v

  let value st = st.value
  let output_to_float x = [x]
end

let make ~period =
  let module M = Make (struct let period = period end) in
  Indicator.make (module M)

(** Chaikin Oscillator = EMA(A/D, fast) - EMA(A/D, slow).
    Streams candles through an internal A/D accumulator and two EMAs
    operating on that accumulator's running value. *)

open Core

module Make (C : sig val fast : int val slow : int end) : Indicator.S = struct
  let () =
    if C.fast <= 0 || C.slow <= 0 then
      invalid_arg "ChaikinOsc: periods must be > 0";
    if C.fast >= C.slow then invalid_arg "ChaikinOsc: fast must be < slow"

  type ema_st = {
    samples : int;
    seed_sum : float;
    value : float option;
  }

  type state = {
    ad : float;
    fast_ema : ema_st;
    slow_ema : ema_st;
  }
  type output = float

  let name = Printf.sprintf "ChaikinOsc(%d,%d)" C.fast C.slow

  let alpha p = 2.0 /. (float_of_int p +. 1.0)
  let af = alpha C.fast
  let aslow = alpha C.slow

  let step_ema period a st x =
    if st.samples < period - 1 then
      { samples = st.samples + 1;
        seed_sum = st.seed_sum +. x;
        value = None }
    else if st.samples = period - 1 then
      let s = st.seed_sum +. x in
      { samples = st.samples + 1;
        seed_sum = s;
        value = Some (s /. float_of_int period) }
    else
      let v = match st.value with Some v -> v | None -> x in
      { st with value = Some (a *. x +. (1.0 -. a) *. v) }

  let init_ema () = { samples = 0; seed_sum = 0.0; value = None }
  let init () = {
    ad = 0.0;
    fast_ema = init_ema ();
    slow_ema = init_ema ();
  }

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let vol = Decimal.to_float c.volume in
    let range = high -. low in
    let mfm = if range = 0.0 then 0.0
              else ((close -. low) -. (high -. close)) /. range in
    let ad' = st.ad +. mfm *. vol in
    let fe = step_ema C.fast af st.fast_ema ad' in
    let se = step_ema C.slow aslow st.slow_ema ad' in
    let st' = { ad = ad'; fast_ema = fe; slow_ema = se } in
    let out = match fe.value, se.value with
      | Some a, Some b -> Some (a -. b)
      | _ -> None
    in
    st', out

  let value st =
    match st.fast_ema.value, st.slow_ema.value with
    | Some a, Some b -> Some (a -. b)
    | _ -> None

  let output_to_float x = [x]
end

let make ?(fast=3) ?(slow=10) () =
  let module Mk = Make (struct let fast = fast let slow = slow end) in
  Indicator.make (module Mk)

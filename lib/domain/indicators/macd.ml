(** MACD = EMA(fast) - EMA(slow); signal = EMA(signal_period, macd);
    histogram = macd - signal. *)

open Core

module Make (C : sig val fast : int val slow : int val signal : int end) :
  Indicator.S = struct
  let () =
    if C.fast <= 0 || C.slow <= 0 || C.signal <= 0 then
      invalid_arg "MACD: periods must be > 0";
    if C.fast >= C.slow then invalid_arg "MACD: fast must be < slow"

  type state = {
    fast_samples : int;
    fast_seed : float;
    fast_ema : float option;
    slow_samples : int;
    slow_seed : float;
    slow_ema : float option;
    signal_samples : int;
    signal_seed : float;
    signal_ema : float option;
  }

  type output = { macd : float; signal : float; hist : float }

  let name =
    Printf.sprintf "MACD(%d,%d,%d)" C.fast C.slow C.signal

  let alpha period = 2.0 /. (float_of_int period +. 1.0)
  let af = alpha C.fast
  let aslow = alpha C.slow
  let asig = alpha C.signal

  let init () = {
    fast_samples = 0; fast_seed = 0.0; fast_ema = None;
    slow_samples = 0; slow_seed = 0.0; slow_ema = None;
    signal_samples = 0; signal_seed = 0.0; signal_ema = None;
  }

  let step_ema period a samples seed ema x =
    if samples < period - 1 then
      samples + 1, seed +. x, None
    else if samples = period - 1 then
      let s = seed +. x in
      samples + 1, s, Some (s /. float_of_int period)
    else
      let v = match ema with Some v -> v | None -> x in
      samples, seed, Some (a *. x +. (1.0 -. a) *. v)

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    let fs, fseed, fema =
      step_ema C.fast af st.fast_samples st.fast_seed st.fast_ema price
    in
    let ss, sseed, sema =
      step_ema C.slow aslow st.slow_samples st.slow_seed st.slow_ema price
    in
    let gs, gseed, gema, macd =
      match fema, sema with
      | Some f, Some s ->
        let macd = f -. s in
        let gs, gseed, gema =
          step_ema C.signal asig st.signal_samples st.signal_seed
            st.signal_ema macd
        in
        gs, gseed, gema, Some macd
      | _ ->
        st.signal_samples, st.signal_seed, st.signal_ema, None
    in
    let st' = {
      fast_samples = fs; fast_seed = fseed; fast_ema = fema;
      slow_samples = ss; slow_seed = sseed; slow_ema = sema;
      signal_samples = gs; signal_seed = gseed; signal_ema = gema;
    } in
    let out = match macd, gema with
      | Some m, Some g -> Some { macd = m; signal = g; hist = m -. g }
      | _ -> None
    in
    st', out

  let value st =
    match st.fast_ema, st.slow_ema, st.signal_ema with
    | Some f, Some s, Some g ->
      let m = f -. s in
      Some { macd = m; signal = g; hist = m -. g }
    | _ -> None

  let output_to_float { macd; signal; hist } = [macd; signal; hist]
end

let make ?(fast=12) ?(slow=26) ?(signal=9) () =
  let module M = Make (struct
    let fast = fast let slow = slow let signal = signal
  end) in
  Indicator.make (module M)

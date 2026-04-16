(** MACD-Weighted: same three-stage structure as MACD but with WMA
    smoothing instead of EMA. Reacts differently near regime changes —
    slow WMA drops old bars completely after [slow] whereas slow EMA
    carries an exponential tail. *)

open Core

module Make (C : sig val fast : int val slow : int val signal : int end) :
  Indicator.S = struct
  let () =
    if C.fast <= 0 || C.slow <= 0 || C.signal <= 0 then
      invalid_arg "MACD-W: periods must be > 0";
    if C.fast >= C.slow then invalid_arg "MACD-W: fast must be < slow"

  type state = {
    fast : float Ring.t;
    slow : float Ring.t;
    macd_hist : float Ring.t;    (* collected macd values to smooth *)
  }
  type output = { macd : float; signal : float; hist : float }

  let name = Printf.sprintf "MACD-W(%d,%d,%d)" C.fast C.slow C.signal

  let denom period = float_of_int (period * (period + 1) / 2)
  let d_fast = denom C.fast
  let d_slow = denom C.slow
  let d_sig  = denom C.signal

  let wma ring denom_ period =
    if Ring.size ring < period then None
    else begin
      let sum = ref 0.0 in
      for i = 0 to period - 1 do
        let w = float_of_int (i + 1) in
        sum := !sum +. Ring.get ring i *. w
      done;
      Some (!sum /. denom_)
    end

  let init () = {
    fast = Ring.create ~capacity:C.fast 0.0;
    slow = Ring.create ~capacity:C.slow 0.0;
    macd_hist = Ring.create ~capacity:C.signal 0.0;
  }

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    let f = Ring.copy st.fast in Ring.push f price;
    let s = Ring.copy st.slow in Ring.push s price;
    let mh = Ring.copy st.macd_hist in
    let macd_opt =
      match wma f d_fast C.fast, wma s d_slow C.slow with
      | Some a, Some b ->
        let m = a -. b in
        Ring.push mh m;
        Some m
      | _ -> None
    in
    let st' = { fast = f; slow = s; macd_hist = mh } in
    let out =
      match macd_opt, wma mh d_sig C.signal with
      | Some m, Some g -> Some { macd = m; signal = g; hist = m -. g }
      | _ -> None
    in
    st', out

  let value st =
    match wma st.fast d_fast C.fast,
          wma st.slow d_slow C.slow,
          wma st.macd_hist d_sig C.signal with
    | Some a, Some b, Some g ->
      let m = a -. b in
      Some { macd = m; signal = g; hist = m -. g }
    | _ -> None

  let output_to_float { macd; signal; hist } = [macd; signal; hist]
end

let make ?(fast=12) ?(slow=26) ?(signal=9) () =
  let module M = Make (struct
    let fast = fast let slow = slow let signal = signal
  end) in
  Indicator.make (module M)

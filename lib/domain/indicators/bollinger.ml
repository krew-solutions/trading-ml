(** Bollinger Bands: middle = SMA(n), upper = middle + k·σ, lower = middle - k·σ.
    σ is the population standard deviation of closes in the window. *)

open Core

module Make (C : sig val period : int val k : float end) :
  Indicator.S = struct
  let () =
    if C.period <= 1 then invalid_arg "Bollinger: period must be > 1";
    if C.k <= 0.0 then invalid_arg "Bollinger: k must be > 0"

  type state = {
    ring : float Ring.t;
    sum : float;
    sum_sq : float;
  }
  type output = { lower : float; middle : float; upper : float }

  let name = Printf.sprintf "BB(%d,%.1f)" C.period C.k
  let n = float_of_int C.period

  let init () = {
    ring = Ring.create ~capacity:C.period 0.0;
    sum = 0.0; sum_sq = 0.0;
  }

  let update st candle =
    let p = Decimal.to_float candle.Candle.close in
    let r = Ring.copy st.ring in
    let st =
      if Ring.is_full st.ring then
        let old = Ring.oldest st.ring in
        Ring.push r p;
        { ring = r;
          sum = st.sum -. old +. p;
          sum_sq = st.sum_sq -. old *. old +. p *. p }
      else begin
        Ring.push r p;
        { ring = r;
          sum = st.sum +. p;
          sum_sq = st.sum_sq +. p *. p }
      end
    in
    let out =
      if Ring.is_full st.ring then
        let mean = st.sum /. n in
        let var = (st.sum_sq /. n) -. mean *. mean in
        let var = if var < 0.0 then 0.0 else var in
        let sd = sqrt var in
        Some { middle = mean;
               upper = mean +. C.k *. sd;
               lower = mean -. C.k *. sd }
      else None
    in
    st, out

  let value st =
    if Ring.is_full st.ring then
      let mean = st.sum /. n in
      let var = (st.sum_sq /. n) -. mean *. mean in
      let var = if var < 0.0 then 0.0 else var in
      let sd = sqrt var in
      Some { middle = mean;
             upper = mean +. C.k *. sd;
             lower = mean -. C.k *. sd }
    else None

  let output_to_float { lower; middle; upper } = [lower; middle; upper]
end

let make ?(period=20) ?(k=2.0) () =
  let module M = Make (struct let period = period let k = k end) in
  Indicator.make (module M)

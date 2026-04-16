(** Chaikin Money Flow.
    mfv_t = ((close - low) - (high - close)) / (high - low) · volume
    CMF_t = Σ(mfv, period) / Σ(volume, period)
    Values range in [-1; 1]; positive = accumulation pressure. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "CMF: period must be > 0"

  type state = {
    mfv_ring : float Ring.t;
    vol_ring : float Ring.t;
    sum_mfv : float;
    sum_vol : float;
  }
  type output = float

  let name = Printf.sprintf "CMF(%d)" C.period

  let init () = {
    mfv_ring = Ring.create ~capacity:C.period 0.0;
    vol_ring = Ring.create ~capacity:C.period 0.0;
    sum_mfv = 0.0; sum_vol = 0.0;
  }

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let vol = Decimal.to_float c.volume in
    let range = high -. low in
    let mfm = if range = 0.0 then 0.0
              else ((close -. low) -. (high -. close)) /. range in
    let mfv = mfm *. vol in
    let mr = Ring.copy st.mfv_ring in
    let vr = Ring.copy st.vol_ring in
    let sum_mfv, sum_vol =
      if Ring.is_full st.mfv_ring then
        let om = Ring.oldest st.mfv_ring in
        let ov = Ring.oldest st.vol_ring in
        Ring.push mr mfv; Ring.push vr vol;
        st.sum_mfv -. om +. mfv, st.sum_vol -. ov +. vol
      else begin
        Ring.push mr mfv; Ring.push vr vol;
        st.sum_mfv +. mfv, st.sum_vol +. vol
      end
    in
    let st' = { mfv_ring = mr; vol_ring = vr; sum_mfv; sum_vol } in
    let out =
      if Ring.is_full mr then
        Some (if sum_vol = 0.0 then 0.0 else sum_mfv /. sum_vol)
      else None
    in
    st', out

  let value st =
    if Ring.is_full st.mfv_ring then
      Some (if st.sum_vol = 0.0 then 0.0 else st.sum_mfv /. st.sum_vol)
    else None

  let output_to_float x = [x]
end

let make ~period =
  let module Mk = Make (struct let period = period end) in
  Indicator.make (module Mk)

(** Stochastic Oscillator (%K, %D).
    %K_t = 100 · (close_t - min_low_n) / (max_high_n - min_low_n)
    %D_t = SMA(%K, d_period)
    If the n-bar high equals the n-bar low the oscillator is defined as 50. *)

open Core

module Make (C : sig val k_period : int val d_period : int end) :
  Indicator.S = struct
  let () =
    if C.k_period <= 0 || C.d_period <= 0 then
      invalid_arg "Stochastic: periods must be > 0"

  type state = {
    highs : float Ring.t;
    lows : float Ring.t;
    k_ring : float Ring.t;
    k_sum : float;
  }
  type output = { k : float; d : float }

  let name = Printf.sprintf "Stoch(%d,%d)" C.k_period C.d_period

  let init () = {
    highs = Ring.create ~capacity:C.k_period 0.0;
    lows  = Ring.create ~capacity:C.k_period 0.0;
    k_ring = Ring.create ~capacity:C.d_period 0.0;
    k_sum = 0.0;
  }

  let min_of r =
    let m = ref infinity in
    Ring.iter r (fun v -> if v < !m then m := v);
    !m

  let max_of r =
    let m = ref neg_infinity in
    Ring.iter r (fun v -> if v > !m then m := v);
    !m

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low  = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let h = Ring.copy st.highs in Ring.push h high;
    let l = Ring.copy st.lows  in Ring.push l low;
    let k_opt =
      if Ring.is_full h then
        let hi = max_of h in
        let lo = min_of l in
        let range = hi -. lo in
        Some (if range = 0.0 then 50.0
              else 100.0 *. (close -. lo) /. range)
      else None
    in
    let st_after =
      match k_opt with
      | None -> { st with highs = h; lows = l }
      | Some kv ->
        let kr = Ring.copy st.k_ring in
        let k_sum =
          if Ring.is_full st.k_ring then
            let old = Ring.oldest st.k_ring in
            Ring.push kr kv;
            st.k_sum -. old +. kv
          else begin
            Ring.push kr kv;
            st.k_sum +. kv
          end
        in
        { highs = h; lows = l; k_ring = kr; k_sum }
    in
    let out =
      match k_opt with
      | None -> None
      | Some kv ->
        if Ring.is_full st_after.k_ring then
          Some { k = kv;
                 d = st_after.k_sum /. float_of_int C.d_period }
        else None
    in
    st_after, out

  let value st =
    if Ring.is_full st.highs && Ring.is_full st.k_ring then
      let k = Ring.newest st.k_ring in
      Some { k; d = st.k_sum /. float_of_int C.d_period }
    else None

  let output_to_float { k; d } = [k; d]
end

let make ?(k_period=14) ?(d_period=3) () =
  let module Mk = Make (struct
    let k_period = k_period let d_period = d_period
  end) in
  Indicator.make (module Mk)

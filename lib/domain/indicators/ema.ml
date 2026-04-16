(** Exponential Moving Average. Seeded with an SMA of the first [period]
    samples, then recursively [ema = α·p + (1 - α)·ema_prev], α = 2/(period+1). *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "EMA: period must be > 0"

  type state = {
    samples : int;
    seed_sum : float;
    value : float option;
  }

  type output = float

  let alpha = 2.0 /. (float_of_int C.period +. 1.0)
  let name = Printf.sprintf "EMA(%d)" C.period

  let init () = { samples = 0; seed_sum = 0.0; value = None }

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    let st =
      if st.samples < C.period - 1 then
        { samples = st.samples + 1;
          seed_sum = st.seed_sum +. price;
          value = None }
      else if st.samples = C.period - 1 then
        let sum = st.seed_sum +. price in
        { samples = st.samples + 1;
          seed_sum = sum;
          value = Some (sum /. float_of_int C.period) }
      else
        let v = match st.value with Some v -> v | None -> price in
        { st with value = Some (alpha *. price +. (1.0 -. alpha) *. v) }
    in
    st, st.value

  let value st = st.value
  let output_to_float x = [x]
end

let make ~period =
  let module M = Make (struct let period = period end) in
  Indicator.make (module M)

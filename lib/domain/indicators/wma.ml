(** Weighted Moving Average with linear weights 1..period.
    Denominator = period·(period+1)/2. Incremental O(period) per bar via
    a ring of the last [period] closes; we re-sum weighted values rather
    than track deltas to keep the code small and numerically stable. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "WMA: period must be > 0"

  type state = { ring : float Ring.t }
  type output = float

  let name = Printf.sprintf "WMA(%d)" C.period
  let denom = float_of_int (C.period * (C.period + 1) / 2)

  let init () = { ring = Ring.create ~capacity:C.period 0.0 }

  let compute ring =
    let n = Ring.size ring in
    let sum = ref 0.0 in
    for i = 0 to n - 1 do
      (* ring.get 0 = oldest; weight for oldest = 1, newest = period. *)
      let w = float_of_int (i + 1) in
      sum := !sum +. Ring.get ring i *. w
    done;
    !sum /. denom

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    let r = Ring.copy st.ring in
    Ring.push r price;
    let st' = { ring = r } in
    let out = if Ring.is_full r then Some (compute r) else None in
    st', out

  let value st =
    if Ring.is_full st.ring then Some (compute st.ring) else None

  let output_to_float x = [x]
end

let make ~period =
  let module M = Make (struct let period = period end) in
  Indicator.make (module M)

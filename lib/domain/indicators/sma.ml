(** Simple Moving Average — arithmetic mean of the last [period] closes.
    Incremental: O(1) per bar. *)

open Core

type config = { period : int }

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "SMA: period must be > 0"

  type state = {
    ring : float Ring.t;
    sum : float;
  }

  type output = float

  let name = Printf.sprintf "SMA(%d)" C.period

  let init () = { ring = Ring.create ~capacity:C.period 0.0; sum = 0.0 }

  let update st candle =
    let price = Decimal.to_float candle.Candle.close in
    let st =
      if Ring.is_full st.ring then
        { ring = (let r = Ring.copy st.ring in Ring.push r price; r);
          sum = st.sum -. Ring.oldest st.ring +. price }
      else begin
        let r = Ring.copy st.ring in
        Ring.push r price;
        { ring = r; sum = st.sum +. price }
      end
    in
    let out =
      if Ring.is_full st.ring then Some (st.sum /. float_of_int C.period)
      else None
    in
    st, out

  let value st =
    if Ring.is_full st.ring then Some (st.sum /. float_of_int C.period)
    else None

  let output_to_float x = [x]
end

let make ~period =
  let module M = Make (struct let period = period end) in
  Indicator.make (module M)

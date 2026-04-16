(** Volume Moving Average: SMA of bar volumes over the last [period] bars.
    Used to flag unusual volume (current vs. its own MA). O(1) per bar via
    a running sum. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "VolumeMA: period must be > 0"

  type state = { ring : float Ring.t; sum : float }
  type output = float

  let name = Printf.sprintf "VolumeMA(%d)" C.period

  let init () = { ring = Ring.create ~capacity:C.period 0.0; sum = 0.0 }

  let update st c =
    let vol = Decimal.to_float c.Candle.volume in
    let r = Ring.copy st.ring in
    let sum =
      if Ring.is_full st.ring then begin
        let old = Ring.oldest st.ring in
        Ring.push r vol;
        st.sum -. old +. vol
      end else begin
        Ring.push r vol;
        st.sum +. vol
      end
    in
    let st' = { ring = r; sum } in
    let out =
      if Ring.is_full r then Some (sum /. float_of_int C.period) else None
    in
    st', out

  let value st =
    if Ring.is_full st.ring then Some (st.sum /. float_of_int C.period)
    else None

  let output_to_float x = [x]
end

let make ~period =
  let module Mk = Make (struct let period = period end) in
  Indicator.make (module Mk)

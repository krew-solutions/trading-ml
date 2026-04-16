(** Money Flow Index — volume-weighted RSI.
    typical_t = (h + l + c) / 3; raw_mf = typical · volume
    positive_t = raw if typical_t > typical_{t-1} else 0
    negative_t = raw if typical_t < typical_{t-1} else 0
    MFI = 100 - 100 / (1 + Σpos/Σneg); MFI = 100 if Σneg = 0. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "MFI: period must be > 0"

  type state = {
    prev_typical : float option;
    pos_ring : float Ring.t;
    neg_ring : float Ring.t;
    sum_pos : float;
    sum_neg : float;
    samples : int;   (* number of signed contributions observed *)
  }
  type output = float

  let name = Printf.sprintf "MFI(%d)" C.period

  let init () = {
    prev_typical = None;
    pos_ring = Ring.create ~capacity:C.period 0.0;
    neg_ring = Ring.create ~capacity:C.period 0.0;
    sum_pos = 0.0; sum_neg = 0.0;
    samples = 0;
  }

  let compute sum_pos sum_neg =
    if sum_neg = 0.0 then 100.0
    else 100.0 -. 100.0 /. (1.0 +. sum_pos /. sum_neg)

  let update st c =
    let high = Decimal.to_float c.Candle.high in
    let low = Decimal.to_float c.low in
    let close = Decimal.to_float c.close in
    let vol = Decimal.to_float c.volume in
    let typical = (high +. low +. close) /. 3.0 in
    let raw = typical *. vol in
    match st.prev_typical with
    | None -> { st with prev_typical = Some typical }, None
    | Some prev ->
      let pos = if typical > prev then raw else 0.0 in
      let neg = if typical < prev then raw else 0.0 in
      let pr = Ring.copy st.pos_ring in
      let nr = Ring.copy st.neg_ring in
      let sum_pos, sum_neg =
        if Ring.is_full st.pos_ring then
          let op = Ring.oldest st.pos_ring in
          let on = Ring.oldest st.neg_ring in
          Ring.push pr pos; Ring.push nr neg;
          st.sum_pos -. op +. pos, st.sum_neg -. on +. neg
        else begin
          Ring.push pr pos; Ring.push nr neg;
          st.sum_pos +. pos, st.sum_neg +. neg
        end
      in
      let samples = st.samples + 1 in
      let st' = {
        prev_typical = Some typical;
        pos_ring = pr; neg_ring = nr;
        sum_pos; sum_neg; samples;
      } in
      let out =
        if samples >= C.period then Some (compute sum_pos sum_neg)
        else None
      in
      st', out

  let value st =
    if st.samples >= C.period then Some (compute st.sum_pos st.sum_neg)
    else None

  let output_to_float x = [x]
end

let make ~period =
  let module Mk = Make (struct let period = period end) in
  Indicator.make (module Mk)

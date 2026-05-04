open Core

(* Notional of a leg at the supplied mark price. *)
let leg_notional mark (tp : Common.Target_position.t) =
  Decimal.mul (Decimal.abs tp.target_qty) (mark tp.instrument)

(* Per-instrument cap: scale [target_qty] down so |target_qty| × mark
   ≤ max_per_instrument_notional. Preserves sign. Treats a non-positive
   mark as a no-op (we have no basis to compute notional). *)
let clip_per_instrument ~max_notional ~mark (tp : Common.Target_position.t) :
    Common.Target_position.t =
  let mark_price = mark tp.instrument in
  if not (Decimal.is_positive mark_price) then tp
  else
    let notional = leg_notional mark tp in
    if Decimal.compare notional max_notional <= 0 then tp
    else
      let cap_qty = Decimal.div max_notional mark_price in
      let target_qty =
        if Decimal.is_negative tp.target_qty then Decimal.neg cap_qty else cap_qty
      in
      { tp with target_qty }

(* Gross-exposure pass: compute Σ leg_notional; if it exceeds
   [max_gross], scale every leg by [max_gross / Σ]. Preserves ratios
   so hedge symmetry survives. *)
let clip_gross ~max_gross ~mark positions =
  let gross =
    List.fold_left
      (fun acc tp -> Decimal.add acc (leg_notional mark tp))
      Decimal.zero positions
  in
  if Decimal.compare gross max_gross <= 0 then positions
  else if Decimal.is_zero gross then positions
  else
    let scale = Decimal.div max_gross gross in
    List.map
      (fun (tp : Common.Target_position.t) ->
        { tp with target_qty = Decimal.mul tp.target_qty scale })
      positions

let clip
    ~(limits : Values.Risk_limits.t)
    ~(mark : Instrument.t -> Decimal.t)
    (proposal : Common.Target_proposal.t) : Common.Target_proposal.t =
  let max_per = Values.Risk_limits.max_per_instrument_notional limits in
  let max_gross = Values.Risk_limits.max_gross_exposure limits in
  let after_per_instrument =
    List.map (clip_per_instrument ~max_notional:max_per ~mark) proposal.positions
  in
  let after_gross = clip_gross ~max_gross ~mark after_per_instrument in
  { proposal with positions = after_gross }

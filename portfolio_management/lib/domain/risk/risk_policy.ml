open Core

(* Notional of a leg at the supplied mark price. *)
let leg_notional mark (tp : Common.Target_position.t) =
  Decimal.mul (Decimal.abs tp.target_qty) (mark tp.instrument)

(* Per-instrument cap: scale a single leg's [target_qty] down so
   |target_qty| × mark ≤ max_per_instrument_notional. Preserves
   sign. Treats a non-positive mark as a no-op (no basis to
   compute notional). *)
let clip_leg_to_per_instrument ~max_notional ~mark (tp : Common.Target_position.t) :
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

(* For a coupling group, the per-instrument cap must apply to the
   group as a whole or the inter-leg ratio breaks. We compute the
   minimum [scale = max_notional / leg_notional] across legs that
   exceed the per-instrument cap, then multiply every leg of the
   group by that scale. When no leg exceeds, the group is
   untouched. *)
let group_scale_for_per_instrument
    ~max_notional
    ~mark
    (legs : Common.Target_position.t list) : Decimal.t =
  List.fold_left
    (fun acc (tp : Common.Target_position.t) ->
      let mark_price = mark tp.instrument in
      if not (Decimal.is_positive mark_price) then acc
      else
        let notional = leg_notional mark tp in
        if Decimal.compare notional max_notional <= 0 then acc
        else
          let s = Decimal.div max_notional notional in
          if Decimal.compare s acc < 0 then s else acc)
    Decimal.one legs

let scale_leg ~scale (tp : Common.Target_position.t) : Common.Target_position.t =
  if Decimal.equal scale Decimal.one then tp
  else { tp with target_qty = Decimal.mul tp.target_qty scale }

(* Per-instrument pass — split coupled vs. independent legs.
   Independent legs are clipped one by one (sign-preserved).
   Coupled legs are grouped by Coupling.t and each group is
   scaled by a single common factor preserving ratios. *)
let clip_per_instrument ~max_notional ~mark (positions : Common.Target_position.t list) :
    Common.Target_position.t list =
  let independents, by_group =
    List.fold_left
      (fun (indep, groups) (tp : Common.Target_position.t) ->
        match tp.coupling with
        | None -> (tp :: indep, groups)
        | Some c -> (
            match List.partition (fun (c', _) -> Common.Coupling.equal c' c) groups with
            | [], rest -> (indep, (c, [ tp ]) :: rest)
            | [ (c', legs) ], rest -> (indep, (c', tp :: legs) :: rest)
            | _ ->
                (* Same coupling cannot appear in two partitions
                   given List.partition; defensive fallthrough. *)
                (indep, (c, [ tp ]) :: groups)))
      ([], []) positions
  in
  let clipped_independents =
    List.rev_map (clip_leg_to_per_instrument ~max_notional ~mark) independents
  in
  let clipped_groups =
    List.concat_map
      (fun (_, legs) ->
        let scale = group_scale_for_per_instrument ~max_notional ~mark legs in
        List.rev_map (scale_leg ~scale) legs)
      by_group
  in
  clipped_independents @ clipped_groups

(* Gross-exposure pass: compute Σ leg_notional; if it exceeds
   [max_gross], scale every leg by [max_gross / Σ]. Preserves
   ratios so hedge symmetry survives across all legs (whether
   coupled or not). *)
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
    List.map (scale_leg ~scale) positions

let clip
    ~(limits : Values.Risk_limits.t)
    ~(mark : Instrument.t -> Decimal.t)
    (proposal : Common.Target_proposal.t) : Common.Target_proposal.t =
  let max_per = Values.Risk_limits.max_per_instrument_notional limits in
  let max_gross = Values.Risk_limits.max_gross_exposure limits in
  let after_per_instrument =
    clip_per_instrument ~max_notional:max_per ~mark proposal.positions
  in
  let after_gross = clip_gross ~max_gross ~mark after_per_instrument in
  { proposal with positions = after_gross }

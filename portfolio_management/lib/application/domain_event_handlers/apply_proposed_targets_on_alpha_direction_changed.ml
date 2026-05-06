module Pm = Portfolio_management
module Direction_changed = Pm.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

(* Sized single-leg target_qty for a given book at the supplied
   direction/strength/price. Returns [Decimal.zero] when the price is
   non-positive (defensive — should not happen if upstream wire is
   well-formed). *)
let size_for_book ~direction ~strength ~price ~notional_cap : Decimal.t =
  if not (Decimal.is_positive price) then Decimal.zero
  else
    let signed_strength = float_of_int (Pm.Common.Direction.sign direction) *. strength in
    let notional_signed = Decimal.mul notional_cap (Decimal.of_float signed_strength) in
    if Decimal.is_zero notional_signed then Decimal.zero
    else Decimal.div notional_signed price

let proposal_for_book
    ~(book_id : Pm.Common.Book_id.t)
    ~(instrument : Core.Instrument.t)
    ~(target_qty : Decimal.t)
    ~(occurred_at : int64) : Pm.Common.Target_proposal.t =
  let position : Pm.Common.Target_position.t = { book_id; instrument; target_qty } in
  { book_id; positions = [ position ]; source = "alpha_view"; proposed_at = occurred_at }

let apply_for_book
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    ~book_id
    proposal =
  let r : Pm.Target_portfolio.t ref = target_portfolio_for book_id in
  match Pm.Target_portfolio.apply_proposal !r proposal with
  | Ok (t', target_set) ->
      r := t';
      Publish_integration_event_on_target_set.handle ~publish_target_portfolio_updated
        target_set
  | Error _ ->
      (* Defensive: per-book book_id mismatch should not happen given
         consistent wiring. Silently skipped here — composition is
         responsible for keeping registries aligned. *)
      ()

let handle
    ~subscribers_for
    ~notional_cap_for
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    (event : Direction_changed.t) : unit =
  let books =
    subscribers_for ~alpha_source_id:event.alpha_source_id ~instrument:event.instrument
  in
  List.iter
    (fun (book_id : Pm.Common.Book_id.t) ->
      let notional_cap = notional_cap_for book_id in
      let target_qty =
        size_for_book ~direction:event.new_direction ~strength:event.strength
          ~price:event.price ~notional_cap
      in
      let proposal =
        proposal_for_book ~book_id ~instrument:event.instrument ~target_qty
          ~occurred_at:event.occurred_at
      in
      apply_for_book ~target_portfolio_for ~publish_target_portfolio_updated ~book_id
        proposal)
    books

module Target_portfolio = Portfolio_management.Target_portfolio
module Common = Portfolio_management.Common

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

(* Apply one proposal to the addressed book and route the resulting
   Target_set domain event through the existing publishing handler.
   Mirror of [apply_for_book] in
   apply_proposed_targets_on_alpha_direction_changed.ml. *)
let apply_for_book
    ~(target_portfolio_for : Common.Book_id.t -> Target_portfolio.t ref)
    ~(publish_target_portfolio_updated : Target_portfolio_updated.t -> unit)
    (proposal : Common.Target_proposal.t) : unit =
  let r = target_portfolio_for proposal.book_id in
  match Target_portfolio.apply_proposal !r proposal with
  | Ok (t', target_set) ->
      r := t';
      Portfolio_management_domain_event_handlers.Publish_integration_event_on_target_set
      .handle ~publish_target_portfolio_updated target_set
  | Error _ ->
      (* Defensive: book_id mismatch between proposal and aggregate
         would indicate a wiring inconsistency. Silently skipped here
         — composition is responsible for keeping registries aligned. *)
      ()

let execute
    ~(pair_mr_states_for :
       Core.Instrument.t -> Portfolio_management.Pair_mean_reversion.state ref list)
    ~(target_portfolio_for : Common.Book_id.t -> Target_portfolio.t ref)
    ~(publish_target_portfolio_updated : Target_portfolio_updated.t -> unit)
    (cmd : Apply_bar_command.t) : (unit, Apply_bar_command_handler.handle_error) Rop.t =
  match Apply_bar_command_handler.handle ~pair_mr_states_for cmd with
  | Ok proposals ->
      List.iter
        (apply_for_book ~target_portfolio_for ~publish_target_portfolio_updated)
        proposals;
      Rop.succeed ()
  | Error errs -> Error errs

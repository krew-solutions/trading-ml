(** ROP pipeline for {!Apply_bar_command.t}.

    Composes {!Apply_bar_command_handler.handle} with the success-
    path projection that applies every emitted target proposal to
    its book's [Target_portfolio] aggregate and publishes a
    {!Target_portfolio_updated_integration_event.t} for each
    successful application.

    Mirrors the structure of
    {!Portfolio_management_domain_event_handlers.Apply_proposed_targets_on_alpha_direction_changed}:
    the construction policy emits raw {!Common.Target_proposal.t}
    values (no policy-specific DE wrapper crossing the application
    boundary), and the workflow body routes each proposal through
    {!Portfolio_management.Target_portfolio.apply_proposal} →
    {!Publish_integration_event_on_target_set}. *)

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val execute :
  pair_mr_states_for:
    (Core.Instrument.t -> Portfolio_management.Pair_mean_reversion.state ref list) ->
  target_portfolio_for:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Target_portfolio.t ref) ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Apply_bar_command.t ->
  (unit, Apply_bar_command_handler.handle_error) Rop.t

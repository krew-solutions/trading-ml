(** ROP pipeline for {!Set_target_command.t}.

    Composes {!Set_target_command_handler.handle} with the success-
    path projection that publishes a
    {!Target_portfolio_updated_integration_event.t} on every accepted
    proposal.

    There is no failure-path projection: validation errors are
    contract violations (no IE), and apply errors (book_id mismatch)
    are also caller bugs in this BC's design — neither produces a
    public outbound event. The error surfaces only on the {!Rop.t}
    tail. *)

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val execute :
  target_portfolio:Portfolio_management.Target_portfolio.t ref ->
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Set_target_command.t ->
  (unit, Set_target_command_handler.handle_error) Rop.t

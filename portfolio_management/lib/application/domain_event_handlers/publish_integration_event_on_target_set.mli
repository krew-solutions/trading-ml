(** Domain-event handler for
    {!Portfolio_management.Target_portfolio.Events.Target_set}.

    Translates the domain event into a
    {!Target_portfolio_updated_integration_event.t} DTO and hands it
    to a Hexagonal Port. The composition root wires that port to the
    outbound Target_portfolio_updated event bus. *)

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

val handle :
  publish_target_portfolio_updated:(Target_portfolio_updated.t -> unit) ->
  Portfolio_management.Target_portfolio.Events.Target_set.t ->
  unit

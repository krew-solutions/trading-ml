(** Domain-event handler for
    {!Portfolio_management.Reconciliation.Events.Trades_planned}.

    Translates the domain event into a
    {!Trade_intents_planned_integration_event.t} DTO and hands it to
    a Hexagonal Port — typically the cross-BC bus consumed by the
    execution layer. *)

module Trade_intents_planned =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

val handle :
  publish_trade_intents_planned:(Trade_intents_planned.t -> unit) ->
  Portfolio_management.Reconciliation.Events.Trades_planned.t ->
  unit

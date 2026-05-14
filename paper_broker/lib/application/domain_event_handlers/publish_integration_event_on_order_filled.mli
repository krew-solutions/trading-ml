(** Domain Event handler: translates {!Paper_broker.Order.Events.Order_filled.t}
    into {!Paper_broker_integration_events.Order_filled_integration_event.t}
    and publishes it through the supplied port closure.

    [correlation_id] is sourced by the caller — typically the
    apply_bar workflow recovers it from the application correlation
    log for the order being filled, since the bar that triggered
    the fill has no correlation_id of its own. *)

module Order_filled :
    module type of Paper_broker_integration_events.Order_filled_integration_event

val handle :
  publish_order_filled:(Order_filled.t -> unit) ->
  correlation_id:string ->
  Paper_broker.Order.Events.Order_filled.t ->
  unit

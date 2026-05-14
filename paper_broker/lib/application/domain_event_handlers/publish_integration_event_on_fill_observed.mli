(** Domain Event handler: translates {!Paper_broker.Order.Events.Fill_observed.t}
    into {!Paper_broker_integration_events.Order_filled_integration_event.t}
    and publishes it through the supplied port closure. *)

module Order_filled :
    module type of Paper_broker_integration_events.Order_filled_integration_event

val handle :
  publish_order_filled:(Order_filled.t -> unit) ->
  correlation_id:string ->
  reservation_id:int ->
  Paper_broker.Order.Events.Fill_observed.t ->
  unit

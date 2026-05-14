(** Domain Event handler: translates {!Paper_broker.Order.Events.Order_cancelled.t}
    into {!Paper_broker_integration_events.Order_cancelled_integration_event.t}
    and publishes it through the supplied port closure. *)

module Order_cancelled :
    module type of Paper_broker_integration_events.Order_cancelled_integration_event

val handle :
  publish_order_cancelled:(Order_cancelled.t -> unit) ->
  correlation_id:string ->
  reservation_id:int ->
  Paper_broker.Order.Events.Order_cancelled.t ->
  unit

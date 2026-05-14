(** Domain Event handler: translates {!Paper_broker.Order.Events.Order_accepted.t}
    into {!Paper_broker_integration_events.Order_accepted_integration_event.t}
    and publishes it through the supplied port closure. *)

module Order_accepted :
    module type of Paper_broker_integration_events.Order_accepted_integration_event

val handle :
  publish_order_accepted:(Order_accepted.t -> unit) ->
  correlation_id:string ->
  reservation_id:int ->
  Paper_broker.Order.Events.Order_accepted.t ->
  unit

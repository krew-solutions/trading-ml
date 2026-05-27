(** Domain Event handler: on [Footprint_completed], project the domain
    event to its outbound integration event and hand it to the publisher
    port. Named for what it does and when (publish on footprint
    completion), not how — per the project's domain-event-handler
    convention. *)

val handle :
  publish_footprint_completed:
    (Order_flow_integration_events.Footprint_completed_integration_event.t -> unit) ->
  Order_flow.Footprint.Events.Footprint_completed.t ->
  unit

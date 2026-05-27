module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

let handle
    ~(publish_footprint_completed : Footprint_completed_ie.t -> unit)
    (ev : Order_flow.Footprint.Events.Footprint_completed.t) : unit =
  publish_footprint_completed (Footprint_completed_ie.of_domain ev)

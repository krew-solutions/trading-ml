module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

let make ~(portfolio : Account.Portfolio.t ref)
    ~(events_reservation_released : Reservation_released.t Bus.Event_bus.t)
    (cmd : Release_command.t) : unit =
  let publish_reservation_released =
    Bus.Event_bus.publish events_reservation_released
  in
  Release_command_workflow.execute ~portfolio ~publish_reservation_released cmd

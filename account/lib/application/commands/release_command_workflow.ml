module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

let execute
    ~(portfolio : Account.Portfolio.t ref)
    ~(publish_reservation_released : Reservation_released.t -> unit)
    (cmd : Release_command.t) : (unit, Release_command_handler.handle_error) Rop.t =
  match Release_command_handler.handle ~portfolio cmd with
  | Ok domain_event ->
      Account_domain_event_handlers.Publish_integration_event_on_reservation_released
      .handle ~publish_reservation_released domain_event;
      Rop.succeed ()
  | Error _ as e -> e

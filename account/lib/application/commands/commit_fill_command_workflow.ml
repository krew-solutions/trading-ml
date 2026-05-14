module Reservation_filled =
  Account_integration_events.Reservation_filled_integration_event

let execute
    ~(portfolio : Account.Portfolio.t ref)
    ~(publish_reservation_filled : Reservation_filled.t -> unit)
    (cmd : Commit_fill_command.t) : (unit, Commit_fill_command_handler.handle_error) Rop.t
    =
  match Commit_fill_command_handler.handle ~portfolio cmd with
  | Ok reservation_filled ->
      Account_domain_event_handlers.Publish_integration_event_on_reservation_filled.handle
        ~publish_reservation_filled ~correlation_id:cmd.correlation_id reservation_filled;
      Rop.succeed ()
  | Error _ as e -> e

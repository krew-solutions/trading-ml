module Reservation_released =
  Account_integration_events.Reservation_released_integration_event

let execute ~(portfolio : Account.Portfolio.t ref)
    ~(publish_reservation_released : Reservation_released.t -> unit)
    (cmd : Release_command.t) : unit =
  match Account.Portfolio.try_release !portfolio ~id:cmd.reservation_id with
  | Ok (portfolio', domain_event) ->
      portfolio := portfolio';
      Account_domain_event_handlers.Publish_integration_event_on_reservation_released
      .handle ~publish_reservation_released domain_event
  | Error (Reservation_not_found _) -> ()

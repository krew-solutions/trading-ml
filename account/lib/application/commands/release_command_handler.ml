let handle ~(portfolio : Account.Portfolio.t ref) (cmd : Release_command.t) :
    ( Account.Portfolio.Events.Reservation_released.t,
      Account.Portfolio.release_error )
    Rop.t =
  let open Rop in
  let* portfolio', domain_event =
    Account.Portfolio.try_release !portfolio ~id:cmd.reservation_id |> of_result
  in
  portfolio := portfolio';
  succeed domain_event

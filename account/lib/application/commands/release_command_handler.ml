let handle ~(portfolio : Account.Portfolio.t ref) (cmd : Release_command.t) :
    (Account.Portfolio.reservation_released, Account.Portfolio.release_error) Rop.t =
  let open Rop in
  let* portfolio', domain_event =
    Account.Portfolio.try_release !portfolio ~id:cmd.reservation_id |> of_result
  in
  portfolio := portfolio';
  succeed domain_event

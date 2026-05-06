type validation_error = Non_positive_reservation_id of int

let validation_error_to_string = function
  | Non_positive_reservation_id n -> Printf.sprintf "reservation_id must be > 0, got %d" n

let release_error_to_string = function
  | Account.Portfolio.Reservation_not_found id ->
      Printf.sprintf "reservation %d not found" id

type validated_release_command = { reservation_id : int }

type handle_error =
  | Validation of validation_error
  | Release of Account.Portfolio.release_error

let parse_reservation_id n : (int, validation_error) Rop.t =
  if n > 0 then Rop.succeed n else Rop.fail (Non_positive_reservation_id n)

let validate (cmd : Release_command.t) :
    (validated_release_command, validation_error) Rop.t =
  let open Rop in
  let+ reservation_id = parse_reservation_id cmd.reservation_id in
  { reservation_id }

let handle ~(portfolio : Account.Portfolio.t ref) (cmd : Release_command.t) :
    (Account.Portfolio.Events.Reservation_released.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match Account.Portfolio.try_release !portfolio ~id:v.reservation_id with
      | Ok (portfolio', domain_event) ->
          portfolio := portfolio';
          Rop.succeed domain_event
      | Error e -> Error [ Release e ])

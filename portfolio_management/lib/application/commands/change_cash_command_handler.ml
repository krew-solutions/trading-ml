module Actual_portfolio = Portfolio_management.Actual_portfolio
module Shared = Portfolio_management.Shared

type validation_error =
  | Invalid_book_id of string
  | Invalid_delta_format of string
  | Invalid_new_balance_format of string
  | Invalid_occurred_at of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_delta_format s -> Printf.sprintf "invalid delta format: %S" s
  | Invalid_new_balance_format s -> Printf.sprintf "invalid new_balance format: %S" s
  | Invalid_occurred_at s -> Printf.sprintf "invalid occurred_at (ISO-8601): %S" s

type validated_command = {
  book_id : Shared.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error | Unknown_book of Shared.Book_id.t

let parse_book_id raw : (Shared.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Shared.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_signed_decimal ~bad_format raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (bad_format raw)

let parse_occurred_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_occurred_at raw) else Rop.succeed parsed

let validate (cmd : Change_cash_command.t) : (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ delta =
    parse_signed_decimal ~bad_format:(fun s -> Invalid_delta_format s) cmd.delta
  and+ new_balance =
    parse_signed_decimal
      ~bad_format:(fun s -> Invalid_new_balance_format s)
      cmd.new_balance
  and+ occurred_at = parse_occurred_at cmd.occurred_at in
  { book_id; delta; new_balance; occurred_at }

let handle
    ~(actual_portfolio_for : Shared.Book_id.t -> Actual_portfolio.t ref option)
    (cmd : Change_cash_command.t) :
    (Actual_portfolio.Events.Actual_cash_changed.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match actual_portfolio_for v.book_id with
      | None -> Error [ Unknown_book v.book_id ]
      | Some r ->
          let actual', event =
            Actual_portfolio.apply_cash_change !r ~delta:v.delta
              ~new_balance:v.new_balance ~occurred_at:v.occurred_at
          in
          r := actual';
          Rop.succeed event)

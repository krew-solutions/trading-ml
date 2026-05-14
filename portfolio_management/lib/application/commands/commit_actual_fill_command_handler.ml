module Actual_portfolio = Portfolio_management.Actual_portfolio
module Common = Portfolio_management.Common

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of string
  | Invalid_new_position_quantity_format of string
  | Invalid_new_avg_price_format of string
  | Negative_new_avg_price of string
  | Invalid_new_cash_format of string
  | Invalid_occurred_at of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_new_position_quantity_format s ->
      Printf.sprintf "invalid new_position_quantity format: %S" s
  | Invalid_new_avg_price_format s -> Printf.sprintf "invalid new_avg_price format: %S" s
  | Negative_new_avg_price s -> Printf.sprintf "new_avg_price must be >= 0, got %s" s
  | Invalid_new_cash_format s -> Printf.sprintf "invalid new_cash format: %S" s
  | Invalid_occurred_at s -> Printf.sprintf "invalid occurred_at (ISO-8601): %S" s

type validated_command = {
  book_id : Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error | Unknown_book of Common.Book_id.t

let parse_book_id raw : (Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

let parse_signed_decimal ~bad_format raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (bad_format raw)

let parse_new_avg_price raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_new_avg_price_format raw)
  | Some d ->
      if Decimal.is_negative d then Rop.fail (Negative_new_avg_price raw)
      else Rop.succeed d

let parse_occurred_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_occurred_at raw) else Rop.succeed parsed

let validate (cmd : Commit_actual_fill_command.t) :
    (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ instrument = parse_instrument cmd.instrument
  and+ new_position_quantity =
    parse_signed_decimal
      ~bad_format:(fun s -> Invalid_new_position_quantity_format s)
      cmd.new_position_quantity
  and+ new_avg_price = parse_new_avg_price cmd.new_avg_price
  and+ new_cash =
    parse_signed_decimal ~bad_format:(fun s -> Invalid_new_cash_format s) cmd.new_cash
  and+ occurred_at = parse_occurred_at cmd.occurred_at in
  { book_id; instrument; new_position_quantity; new_avg_price; new_cash; occurred_at }

let handle
    ~(actual_portfolio_for : Common.Book_id.t -> Actual_portfolio.t ref option)
    (cmd : Commit_actual_fill_command.t) :
    (Actual_portfolio.Events.Actual_fill_committed.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match actual_portfolio_for v.book_id with
      | None -> Error [ Unknown_book v.book_id ]
      | Some r ->
          let actual', event =
            Actual_portfolio.commit_fill !r ~instrument:v.instrument
              ~new_position_quantity:v.new_position_quantity
              ~new_avg_price:v.new_avg_price ~new_cash:v.new_cash
              ~occurred_at:v.occurred_at
          in
          r := actual';
          Rop.succeed event)

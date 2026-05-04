module Reconciliation = Portfolio_management.Reconciliation
module Target_portfolio = Portfolio_management.Target_portfolio
module Actual_portfolio = Portfolio_management.Actual_portfolio
module Common = Portfolio_management.Common

type validation_error = Invalid_book_id of string | Invalid_computed_at of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_computed_at s -> Printf.sprintf "invalid computed_at (ISO-8601): %S" s

type validated_command = { book_id : Common.Book_id.t; computed_at : int64 }

type handle_error = Validation of validation_error | Unknown_book of Common.Book_id.t

let parse_book_id raw : (Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_computed_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_computed_at raw) else Rop.succeed parsed

let validate (cmd : Reconcile_command.t) : (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ computed_at = parse_computed_at cmd.computed_at in
  { book_id; computed_at }

let handle
    ~(target_portfolio_for : Common.Book_id.t -> Target_portfolio.t option)
    ~(actual_portfolio_for : Common.Book_id.t -> Actual_portfolio.t option)
    (cmd : Reconcile_command.t) :
    (Reconciliation.Events.Trades_planned.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match (target_portfolio_for v.book_id, actual_portfolio_for v.book_id) with
      | None, _ | _, None -> Error [ Unknown_book v.book_id ]
      | Some target, Some actual ->
          let _trades, event =
            Reconciliation.diff_with_event ~target ~actual ~computed_at:v.computed_at
          in
          Rop.succeed event)

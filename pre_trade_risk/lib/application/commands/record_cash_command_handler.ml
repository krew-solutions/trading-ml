type validation_error =
  | Invalid_book_id of string
  | Invalid_delta of string
  | Invalid_new_balance of string
  | Invalid_occurred_at of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_delta s -> Printf.sprintf "invalid delta: %S" s
  | Invalid_new_balance s -> Printf.sprintf "invalid new_balance: %S" s
  | Invalid_occurred_at s -> Printf.sprintf "invalid occurred_at (ISO-8601): %S" s

type validated_command = {
  book_id : Pre_trade_risk.Common.Book_id.t;
  delta : Decimal.t;
  new_balance : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error

let parse_book_id raw : (Pre_trade_risk.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pre_trade_risk.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_decimal ~bad raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad raw)
  | Some d -> Rop.succeed d

let parse_occurred_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_occurred_at raw) else Rop.succeed parsed

let validate (cmd : Record_cash_command.t) : (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ delta = parse_decimal ~bad:(fun s -> Invalid_delta s) cmd.delta
  and+ new_balance = parse_decimal ~bad:(fun s -> Invalid_new_balance s) cmd.new_balance
  and+ occurred_at = parse_occurred_at cmd.occurred_at in
  { book_id; delta; new_balance; occurred_at }

let handle
    ~(risk_view_ref_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref)
    (cmd : Record_cash_command.t) :
    (Pre_trade_risk.Risk_view.Events.Cash_recorded.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v ->
      let view_ref = risk_view_ref_for v.book_id in
      let view', event =
        Pre_trade_risk.Risk_view.apply_cash_change !view_ref ~delta:v.delta
          ~new_balance:v.new_balance ~occurred_at:v.occurred_at
      in
      view_ref := view';
      Rop.succeed event

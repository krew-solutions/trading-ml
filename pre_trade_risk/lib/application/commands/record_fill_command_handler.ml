type validation_error =
  | Invalid_book_id of string
  | Invalid_symbol of string
  | Invalid_new_position_quantity of string
  | Invalid_new_avg_price of string
  | Invalid_new_cash of string
  | Invalid_occurred_at of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_new_position_quantity s ->
      Printf.sprintf "invalid new_position_quantity: %S" s
  | Invalid_new_avg_price s -> Printf.sprintf "invalid new_avg_price: %S" s
  | Invalid_new_cash s -> Printf.sprintf "invalid new_cash: %S" s
  | Invalid_occurred_at s -> Printf.sprintf "invalid occurred_at (ISO-8601): %S" s

type validated_command = {
  book_id : Pre_trade_risk.Common.Book_id.t;
  instrument : Core.Instrument.t;
  new_position_quantity : Decimal.t;
  new_avg_price : Decimal.t;
  new_cash : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error

let parse_book_id raw : (Pre_trade_risk.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pre_trade_risk.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_decimal ~bad raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad raw)
  | Some d -> Rop.succeed d

let parse_occurred_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_occurred_at raw) else Rop.succeed parsed

let validate (cmd : Record_fill_command.t) : (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ instrument = parse_instrument cmd.symbol
  and+ new_position_quantity =
    parse_decimal
      ~bad:(fun s -> Invalid_new_position_quantity s)
      cmd.new_position_quantity
  and+ new_avg_price =
    parse_decimal ~bad:(fun s -> Invalid_new_avg_price s) cmd.new_avg_price
  and+ new_cash = parse_decimal ~bad:(fun s -> Invalid_new_cash s) cmd.new_cash
  and+ occurred_at = parse_occurred_at cmd.occurred_at in
  { book_id; instrument; new_position_quantity; new_avg_price; new_cash; occurred_at }

let handle
    ~(risk_view_ref_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t ref)
    (cmd : Record_fill_command.t) :
    (Pre_trade_risk.Risk_view.Events.Fill_recorded.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v ->
      let view_ref = risk_view_ref_for v.book_id in
      let view', event =
        Pre_trade_risk.Risk_view.commit_fill !view_ref ~instrument:v.instrument
          ~new_position_quantity:v.new_position_quantity ~new_avg_price:v.new_avg_price
          ~new_cash:v.new_cash ~occurred_at:v.occurred_at
      in
      view_ref := view';
      Rop.succeed event

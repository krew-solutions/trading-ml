type validation_error =
  | Invalid_book_id of string
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Negative_price of string
  | Empty_correlation_id

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_side s -> Printf.sprintf "invalid side: %S (expected BUY | SELL)" s
  | Invalid_quantity_format s -> Printf.sprintf "invalid quantity format: %S" s
  | Non_positive_quantity s -> Printf.sprintf "quantity must be > 0, got %s" s
  | Invalid_price_format s -> Printf.sprintf "invalid price format: %S" s
  | Negative_price s -> Printf.sprintf "price must be >= 0, got %s" s
  | Empty_correlation_id -> "correlation_id must not be empty"

type validated_command = {
  correlation_id : string;
  book_id : Pre_trade_risk.Common.Book_id.t;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
}

type handle_error =
  | Validation of validation_error
  | Unknown_book of Pre_trade_risk.Common.Book_id.t

let parse_correlation_id raw : (string, validation_error) Rop.t =
  if raw = "" then Rop.fail Empty_correlation_id else Rop.succeed raw

let parse_book_id raw : (Pre_trade_risk.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pre_trade_risk.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_side raw : (Core.Side.t, validation_error) Rop.t =
  try Rop.succeed (Core.Side.of_string (String.uppercase_ascii raw))
  with Invalid_argument _ -> Rop.fail (Invalid_side raw)

let parse_positive_decimal raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_quantity_format raw)
  | Some d ->
      if Decimal.is_positive d then Rop.succeed d
      else Rop.fail (Non_positive_quantity raw)

let parse_non_negative_decimal raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_price_format raw)
  | Some d ->
      if Decimal.is_negative d then Rop.fail (Negative_price raw) else Rop.succeed d

let validate (cmd : Assess_trade_intent_command.t) :
    (validated_command, validation_error) Rop.t =
  let open Rop in
  let+ correlation_id = parse_correlation_id cmd.correlation_id
  and+ book_id = parse_book_id cmd.book_id
  and+ instrument = parse_instrument cmd.symbol
  and+ side = parse_side cmd.side
  and+ quantity = parse_positive_decimal cmd.quantity
  and+ price = parse_non_negative_decimal cmd.price in
  { correlation_id; book_id; instrument; side; quantity; price }

let handle
    ~(risk_view_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option)
    ~(limits : Pre_trade_risk.Risk_limits.t)
    ~(mark : Core.Instrument.t -> Decimal.t option)
    (cmd : Assess_trade_intent_command.t) :
    (validated_command * Pre_trade_risk.Assessment.outcome, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match risk_view_for v.book_id with
      | None -> Error [ Unknown_book v.book_id ]
      | Some view ->
          let outcome =
            Pre_trade_risk.Assessment.assess ~view ~limits ~side:v.side
              ~instrument:v.instrument ~quantity:v.quantity ~price:v.price ~mark
          in
          Rop.succeed (v, outcome))

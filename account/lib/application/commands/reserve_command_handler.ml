type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Non_positive_price of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_side s -> Printf.sprintf "invalid side: %S (expected BUY | SELL)" s
  | Invalid_quantity_format s -> Printf.sprintf "invalid quantity format: %S" s
  | Non_positive_quantity s -> Printf.sprintf "quantity must be > 0, got %s" s
  | Invalid_price_format s -> Printf.sprintf "invalid price format: %S" s
  | Non_positive_price s -> Printf.sprintf "price must be > 0, got %s" s

let reservation_error_to_string = function
  | Account.Portfolio.Insufficient_cash { required; available } ->
      Printf.sprintf "insufficient cash: required %s, available %s"
        (Decimal.to_string required) (Decimal.to_string available)
  | Account.Portfolio.Insufficient_margin { required; available } ->
      Printf.sprintf "insufficient margin: required %s, available %s"
        (Decimal.to_string required) (Decimal.to_string available)

type validated_reserve_command = {
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  quantity : Decimal.t;
  price : Decimal.t;
}

type handle_error =
  | Validation of validation_error
  | Reservation of {
      attempted : validated_reserve_command;
      error : Account.Portfolio.reservation_error;
    }

let parse_side raw : (Core.Side.t, validation_error) Rop.t =
  try Rop.succeed (Core.Side.of_string (String.uppercase_ascii raw))
  with Invalid_argument _ -> Rop.fail (Invalid_side raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_positive_decimal ~bad_format ~not_positive raw :
    (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad_format raw)
  | Some d -> if Decimal.is_positive d then Rop.succeed d else Rop.fail (not_positive raw)

let parse_quantity =
  parse_positive_decimal
    ~bad_format:(fun s -> Invalid_quantity_format s)
    ~not_positive:(fun s -> Non_positive_quantity s)

let parse_price =
  parse_positive_decimal
    ~bad_format:(fun s -> Invalid_price_format s)
    ~not_positive:(fun s -> Non_positive_price s)

let validate (cmd : Reserve_command.t) :
    (validated_reserve_command, validation_error) Rop.t =
  let open Rop in
  let+ side = parse_side cmd.side
  and+ instrument = parse_instrument cmd.symbol
  and+ quantity = parse_quantity cmd.quantity
  and+ price = parse_price cmd.price in
  { side; instrument; quantity; price }

let handle
    ~(portfolio : Account.Portfolio.t ref)
    ~(next_reservation_id : unit -> int)
    ~(slippage_buffer : Decimal.t)
    ~(fee_rate : Decimal.t)
    ~(margin_policy : Account.Portfolio.Margin_policy.t)
    ~(mark : Core.Instrument.t -> Decimal.t option)
    (cmd : Reserve_command.t) :
    (Account.Portfolio.Events.Amount_reserved.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      let id = next_reservation_id () in
      match
        Account.Portfolio.try_reserve !portfolio ~id ~side:v.side ~instrument:v.instrument
          ~quantity:v.quantity ~price:v.price ~slippage_buffer ~fee_rate ~margin_policy
          ~mark
      with
      | Ok (portfolio', domain_event) ->
          portfolio := portfolio';
          Rop.succeed domain_event
      | Error e -> Error [ Reservation { attempted = v; error = e } ])

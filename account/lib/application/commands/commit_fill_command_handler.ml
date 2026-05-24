type validation_error =
  | Non_positive_reservation_id of int
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Non_positive_price of string
  | Invalid_fee_format of string
  | Negative_fee of string

let validation_error_to_string = function
  | Non_positive_reservation_id n -> Printf.sprintf "reservation_id must be > 0, got %d" n
  | Invalid_quantity_format s -> Printf.sprintf "invalid quantity format: %S" s
  | Non_positive_quantity s -> Printf.sprintf "quantity must be > 0, got %s" s
  | Invalid_price_format s -> Printf.sprintf "invalid price format: %S" s
  | Non_positive_price s -> Printf.sprintf "price must be > 0, got %s" s
  | Invalid_fee_format s -> Printf.sprintf "invalid fee format: %S" s
  | Negative_fee s -> Printf.sprintf "fee must be >= 0, got %s" s

type validated_commit_fill_command = {
  reservation_id : int;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

let commit_fill_error_to_string : Account.Portfolio.commit_fill_error -> string = function
  | Account.Portfolio.Reservation_not_found id ->
      Printf.sprintf "reservation %d not found" id
  | Account.Portfolio.Overfill { id; attempted; remaining } ->
      Printf.sprintf "overfill on reservation %d: attempted %s, remaining %s" id
        (Decimal.to_string attempted) (Decimal.to_string remaining)

type handle_error =
  | Validation of validation_error
  | Commit of Account.Portfolio.commit_fill_error

let parse_reservation_id n : (int, validation_error) Rop.t =
  if n > 0 then Rop.succeed n else Rop.fail (Non_positive_reservation_id n)

let parse_positive_decimal ~bad_format ~not_positive raw :
    (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad_format raw)
  | Some d -> if Decimal.is_positive d then Rop.succeed d else Rop.fail (not_positive raw)

let parse_non_negative_decimal ~bad_format ~negative raw :
    (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (bad_format raw)
  | Some d -> if Decimal.is_negative d then Rop.fail (negative raw) else Rop.succeed d

let parse_quantity =
  parse_positive_decimal
    ~bad_format:(fun s -> Invalid_quantity_format s)
    ~not_positive:(fun s -> Non_positive_quantity s)

let parse_price =
  parse_positive_decimal
    ~bad_format:(fun s -> Invalid_price_format s)
    ~not_positive:(fun s -> Non_positive_price s)

let parse_fee =
  parse_non_negative_decimal
    ~bad_format:(fun s -> Invalid_fee_format s)
    ~negative:(fun s -> Negative_fee s)

let validate (cmd : Commit_fill_command.t) :
    (validated_commit_fill_command, validation_error) Rop.t =
  let open Rop in
  let+ reservation_id = parse_reservation_id cmd.reservation_id
  and+ quantity = parse_quantity cmd.quantity
  and+ price = parse_price cmd.price
  and+ fee = parse_fee cmd.fee in
  { reservation_id; quantity; price; fee }

let handle ~(portfolio : Account.Portfolio.t ref) (cmd : Commit_fill_command.t) :
    (Account.Portfolio.commit_fill_outcome, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      match
        Account.Portfolio.commit_fill !portfolio ~id:v.reservation_id
          ~actual_quantity:v.quantity ~actual_price:v.price ~actual_fee:v.fee
      with
      | Ok (portfolio', outcome) ->
          portfolio := portfolio';
          Rop.succeed outcome
      | Error e -> Error [ Commit e ])

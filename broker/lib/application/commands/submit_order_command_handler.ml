open Core

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Invalid_kind of string
  | Invalid_kind_price_format of { field : string; value : string }
  | Missing_kind_price of { kind : string; field : string }
  | Invalid_tif of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_side s -> Printf.sprintf "invalid side: %S (expected BUY | SELL)" s
  | Invalid_quantity_format s -> Printf.sprintf "invalid quantity format: %S" s
  | Invalid_kind s ->
      Printf.sprintf "invalid kind: %S (expected MARKET | LIMIT | STOP | STOP_LIMIT)" s
  | Invalid_kind_price_format { field; value } ->
      Printf.sprintf "invalid %s format: %S" field value
  | Missing_kind_price { kind; field } -> Printf.sprintf "%s requires %s" kind field
  | Invalid_tif s -> Printf.sprintf "invalid tif: %S (expected GTC | DAY | IOC | FOK)" s

type validated_submit_order_command = {
  correlation_id : string;
  placement_id : int;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
}

type broker_outcome =
  | Accepted of Order.t
  | Rejected of { order : Order.t; reason : string }
  | Unreachable of { reason : string }

type handle_error = Validation of validation_error

let parse_instrument raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ | Failure _ -> Rop.fail (Invalid_symbol raw)

let parse_side raw : (Side.t, validation_error) Rop.t =
  match String.uppercase_ascii raw with
  | "BUY" -> Rop.succeed Side.Buy
  | "SELL" -> Rop.succeed Side.Sell
  | _ -> Rop.fail (Invalid_side raw)

let parse_quantity raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_quantity_format raw)

let parse_decimal_field ~field ~raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_kind_price_format { field; value = raw })

let parse_tif raw : (Order.time_in_force, validation_error) Rop.t =
  match String.uppercase_ascii raw with
  | "GTC" -> Rop.succeed Order.GTC
  | "DAY" -> Rop.succeed Order.DAY
  | "IOC" -> Rop.succeed Order.IOC
  | "FOK" -> Rop.succeed Order.FOK
  | _ -> Rop.fail (Invalid_tif raw)

let parse_kind (k : Order_kind_view_model.t) : (Order.kind, validation_error) Rop.t =
  match String.uppercase_ascii k.type_ with
  | "MARKET" -> Rop.succeed Order.Market
  | "LIMIT" -> (
      match k.price with
      | None -> Rop.fail (Missing_kind_price { kind = "LIMIT"; field = "price" })
      | Some raw ->
          let open Rop in
          let+ price = parse_decimal_field ~field:"price" ~raw in
          Order.Limit price)
  | "STOP" -> (
      match k.price with
      | None -> Rop.fail (Missing_kind_price { kind = "STOP"; field = "price" })
      | Some raw ->
          let open Rop in
          let+ price = parse_decimal_field ~field:"price" ~raw in
          Order.Stop price)
  | "STOP_LIMIT" ->
      let open Rop in
      let stop_field =
        match k.stop_price with
        | None -> fail (Missing_kind_price { kind = "STOP_LIMIT"; field = "stop_price" })
        | Some raw -> parse_decimal_field ~field:"stop_price" ~raw
      in
      let limit_field =
        match k.limit_price with
        | None -> fail (Missing_kind_price { kind = "STOP_LIMIT"; field = "limit_price" })
        | Some raw -> parse_decimal_field ~field:"limit_price" ~raw
      in
      let+ stop = stop_field and+ limit = limit_field in
      Order.Stop_limit { stop; limit }
  | _ -> Rop.fail (Invalid_kind k.type_)

let validate (cmd : Submit_order_command.t) :
    (validated_submit_order_command, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_instrument cmd.symbol
  and+ side = parse_side cmd.side
  and+ quantity = parse_quantity cmd.quantity
  and+ kind = parse_kind cmd.kind
  and+ tif = parse_tif cmd.tif in
  {
    correlation_id = cmd.correlation_id;
    placement_id = cmd.placement_id;
    instrument;
    side;
    quantity;
    kind;
    tif;
  }

let place ~(broker : Broker.client) (v : validated_submit_order_command) : broker_outcome
    =
  let client_order_id = Broker.generate_client_order_id broker in
  match
    try
      Ok
        (Broker.place_order broker ~instrument:v.instrument ~side:v.side
           ~quantity:v.quantity ~kind:v.kind ~tif:v.tif ~client_order_id)
    with e -> Error (Printexc.to_string e)
  with
  | Error reason -> Unreachable { reason }
  | Ok order -> (
      match order.status with
      | Rejected -> Rejected { order; reason = Order.status_to_string order.status }
      | _ -> Accepted order)

let handle ~(broker : Broker.client) (cmd : Submit_order_command.t) :
    (broker_outcome, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> Rop.succeed (place ~broker v)

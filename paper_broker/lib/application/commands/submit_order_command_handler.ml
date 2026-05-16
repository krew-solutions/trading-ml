module Order = Paper_broker.Order
module Order_kind = Order.Values.Order_kind
module Order_kind_view_model = Paper_broker_view_models.Order_kind_view_model
module Placement_id = Order.Values.Placement_id
module Time_in_force = Order.Values.Time_in_force

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Non_positive_placement_id of int
  | Invalid_kind of string
  | Invalid_kind_price_format of { field : string; value : string }
  | Non_positive_kind_price of { field : string; value : string }
  | Missing_kind_price of { kind : string; field : string }
  | Invalid_tif of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_side s -> Printf.sprintf "invalid side: %S (expected BUY | SELL)" s
  | Invalid_quantity_format s -> Printf.sprintf "invalid quantity format: %S" s
  | Non_positive_quantity s -> Printf.sprintf "quantity must be > 0, got %s" s
  | Non_positive_placement_id n -> Printf.sprintf "placement_id must be > 0, got %d" n
  | Invalid_kind s ->
      Printf.sprintf "invalid kind: %S (expected MARKET | LIMIT | STOP | STOP_LIMIT)" s
  | Invalid_kind_price_format { field; value } ->
      Printf.sprintf "invalid %s format: %S" field value
  | Non_positive_kind_price { field; value } ->
      Printf.sprintf "%s must be > 0, got %s" field value
  | Missing_kind_price { kind; field } -> Printf.sprintf "%s requires %s" kind field
  | Invalid_tif s -> Printf.sprintf "invalid tif: %S (expected GTC | DAY | IOC | FOK)" s

type validated_submit_order_command = {
  correlation_id : string;
  placement_id : Placement_id.t;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  kind : Order_kind.t;
  tif : Time_in_force.t;
}

type handle_error = Validation of validation_error

let parse_side raw : (Core.Side.t, validation_error) Rop.t =
  try Rop.succeed (Core.Side.of_string (String.uppercase_ascii raw))
  with Invalid_argument _ -> Rop.fail (Invalid_side raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_positive_decimal_field ~field ~raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_kind_price_format { field; value = raw })
  | Some d ->
      if Decimal.is_positive d then Rop.succeed d
      else Rop.fail (Non_positive_kind_price { field; value = raw })

let parse_quantity raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_quantity_format raw)
  | Some d ->
      if Decimal.is_positive d then Rop.succeed d
      else Rop.fail (Non_positive_quantity raw)

let parse_placement_id n : (Placement_id.t, validation_error) Rop.t =
  try Rop.succeed (Placement_id.of_int n)
  with Invalid_argument _ -> Rop.fail (Non_positive_placement_id n)

let parse_tif raw : (Time_in_force.t, validation_error) Rop.t =
  match String.uppercase_ascii raw with
  | "GTC" -> Rop.succeed Time_in_force.GTC
  | "DAY" -> Rop.succeed Time_in_force.DAY
  | "IOC" -> Rop.succeed Time_in_force.IOC
  | "FOK" -> Rop.succeed Time_in_force.FOK
  | _ -> Rop.fail (Invalid_tif raw)

let parse_kind (k : Order_kind_view_model.t) : (Order_kind.t, validation_error) Rop.t =
  let tag = String.uppercase_ascii k.type_ in
  match tag with
  | "MARKET" -> Rop.succeed Order_kind.market
  | "LIMIT" -> (
      match k.price with
      | None -> Rop.fail (Missing_kind_price { kind = "LIMIT"; field = "price" })
      | Some raw -> (
          match parse_positive_decimal_field ~field:"price" ~raw with
          | Ok d -> Rop.succeed (Order_kind.limit d)
          | Error errs -> Error errs))
  | "STOP" -> (
      match k.price with
      | None -> Rop.fail (Missing_kind_price { kind = "STOP"; field = "price" })
      | Some raw -> (
          match parse_positive_decimal_field ~field:"price" ~raw with
          | Ok d -> Rop.succeed (Order_kind.stop d)
          | Error errs -> Error errs))
  | "STOP_LIMIT" ->
      let open Rop in
      let stop_field =
        match k.stop_price with
        | None -> fail (Missing_kind_price { kind = "STOP_LIMIT"; field = "stop_price" })
        | Some raw -> parse_positive_decimal_field ~field:"stop_price" ~raw
      in
      let limit_field =
        match k.limit_price with
        | None -> fail (Missing_kind_price { kind = "STOP_LIMIT"; field = "limit_price" })
        | Some raw -> parse_positive_decimal_field ~field:"limit_price" ~raw
      in
      let+ stop = stop_field and+ limit = limit_field in
      Order_kind.stop_limit ~stop ~limit
  | _ -> Rop.fail (Invalid_kind k.type_)

let validate (cmd : Submit_order_command.t) :
    (validated_submit_order_command, validation_error) Rop.t =
  let open Rop in
  let+ side = parse_side cmd.side
  and+ instrument = parse_instrument cmd.symbol
  and+ quantity = parse_quantity cmd.quantity
  and+ placement_id = parse_placement_id cmd.placement_id
  and+ kind = parse_kind cmd.kind
  and+ tif = parse_tif cmd.tif in
  {
    correlation_id = cmd.correlation_id;
    placement_id;
    instrument;
    side;
    quantity;
    kind;
    tif;
  }

module type Store = Paper_broker_store.Order_store.S

let handle
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(next_order_id : unit -> string)
    ~(now_ts : unit -> int64)
    ~(placed_after_ts : Core.Instrument.t -> int64)
    (cmd : Submit_order_command.t) :
    (Order.t * Order.Events.Order_accepted.t, handle_error) Rop.t =
  let module S = (val store : Store with type t = store) in
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v ->
      let id = next_order_id () in
      let created_ts = now_ts () in
      let placed_after_ts = placed_after_ts v.instrument in
      let order, event =
        Order.make ~id ~placement_id:v.placement_id ~instrument:v.instrument ~side:v.side
          ~quantity:v.quantity ~kind:v.kind ~tif:v.tif ~created_ts ~placed_after_ts
      in
      (match S.save store_handle order with
      | `Ok -> ()
      | `Already_exists ->
          invalid_arg
            (Printf.sprintf
               "Submit_order_command_handler: next_order_id %S collided in store" id));
      Rop.succeed (order, event)

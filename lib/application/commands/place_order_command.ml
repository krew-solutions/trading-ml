open Core

type t = {
  symbol : string;
  side : string;
  quantity : float;
  kind : Queries.Order_kind_view_model.t;
  tif : string;
  client_order_id : string;
}
[@@deriving yojson]

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Non_positive_quantity of float
  | Unknown_kind_type of string
  | Missing_kind_price of { kind_type : string; field : string }
  | Invalid_tif of string
  | Missing_client_order_id

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_side s -> Printf.sprintf "invalid side: %S (expected BUY | SELL)" s
  | Non_positive_quantity q -> Printf.sprintf "quantity must be > 0, got %g" q
  | Unknown_kind_type s ->
      Printf.sprintf "unknown kind type: %S (expected MARKET | LIMIT | STOP | STOP_LIMIT)"
        s
  | Missing_kind_price { kind_type; field } ->
      Printf.sprintf "kind %s: missing required field %S" kind_type field
  | Invalid_tif s -> Printf.sprintf "invalid tif: %S (expected GTC | DAY | IOC | FOK)" s
  | Missing_client_order_id -> "client_order_id is required"

type unvalidated = {
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  client_order_id : string;
}

let reservation_error_to_string = function
  | Engine.Portfolio.Insufficient_cash { required; available } ->
      Printf.sprintf "insufficient cash: required %s, available %s"
        (Decimal.to_string required) (Decimal.to_string available)
  | Engine.Portfolio.Insufficient_qty { required; available } ->
      Printf.sprintf "insufficient quantity: required %s, available %s"
        (Decimal.to_string required) (Decimal.to_string available)

let reserve
    ~(portfolio : Engine.Portfolio.t)
    ~(market_price : Decimal.t)
    ~(slippage_buffer : float)
    ~(fee_rate : float)
    ~(next_reservation_id : unit -> int)
    (u : unvalidated) :
    ( Engine.Portfolio.t * Engine.Portfolio.amount_reserved,
      Engine.Portfolio.reservation_error )
    Rop.t =
  let id = next_reservation_id () in
  Rop.of_result
    (Engine.Portfolio.try_reserve portfolio ~id ~side:u.side ~instrument:u.instrument
       ~quantity:u.quantity ~price:market_price ~slippage_buffer ~fee_rate)

let parse_symbol raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_side raw : (Side.t, validation_error) Rop.t =
  try Rop.succeed (Side.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_side raw)

let parse_quantity q : (Decimal.t, validation_error) Rop.t =
  if q <= 0.0 then Rop.fail (Non_positive_quantity q)
  else Rop.succeed (Decimal.of_float q)

(** Parse the DTO kind subtree. Only surfaces the first missing
    price field per kind — a STOP_LIMIT with both [stop_price]
    and [limit_price] absent reports [stop_price] as missing;
    the caller fixes that and resubmits. Could accumulate more
    aggressively, but validating the outer fields' primary
    shape is the 80% case and deeper accumulation hasn't paid
    off yet. *)
let parse_kind (k : Queries.Order_kind_view_model.t) :
    (Order.kind, validation_error) Rop.t =
  let missing kind_type field = Rop.fail (Missing_kind_price { kind_type; field }) in
  match String.uppercase_ascii k.type_ with
  | "MARKET" -> Rop.succeed Order.Market
  | "LIMIT" -> (
      match k.price with
      | Some p -> Rop.succeed (Order.Limit (Decimal.of_float p))
      | None -> missing "LIMIT" "price")
  | "STOP" -> (
      match k.price with
      | Some p -> Rop.succeed (Order.Stop (Decimal.of_float p))
      | None -> missing "STOP" "price")
  | "STOP_LIMIT" -> (
      match (k.stop_price, k.limit_price) with
      | Some s, Some l ->
          Rop.succeed
            (Order.Stop_limit { stop = Decimal.of_float s; limit = Decimal.of_float l })
      | None, _ -> missing "STOP_LIMIT" "stop_price"
      | _, None -> missing "STOP_LIMIT" "limit_price")
  | other -> Rop.fail (Unknown_kind_type other)

let parse_tif raw : (Order.time_in_force, validation_error) Rop.t =
  match String.uppercase_ascii raw with
  | "GTC" -> Rop.succeed Order.GTC
  | "DAY" -> Rop.succeed Order.DAY
  | "IOC" -> Rop.succeed Order.IOC
  | "FOK" -> Rop.succeed Order.FOK
  | _ -> Rop.fail (Invalid_tif raw)

let parse_client_order_id raw : (string, validation_error) Rop.t =
  if String.trim raw = "" then Rop.fail Missing_client_order_id else Rop.succeed raw

let to_unvalidated (t : t) : (unvalidated, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_symbol t.symbol
  and+ side = parse_side t.side
  and+ quantity = parse_quantity t.quantity
  and+ kind = parse_kind t.kind
  and+ tif = parse_tif t.tif
  and+ client_order_id = parse_client_order_id t.client_order_id in
  { instrument; side; quantity; kind; tif; client_order_id }

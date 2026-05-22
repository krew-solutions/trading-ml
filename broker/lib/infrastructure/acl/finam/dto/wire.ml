(** Low-level wire helpers used by the per-record DTO modules
    in [Finam.Dto]. Decimal parsing tolerant of all formats the
    Finam gRPC → REST bridge ships (string, int, float, intlit,
    and the [{"value": "..."}] proto-Decimal wrapper with
    optional [scale]); enum codecs for the per-field wire
    constants ([SIDE_BUY], [ORDER_TYPE_LIMIT], …).

    Lives as its own submodule (not as functions on the
    {!Dto} wrapper) so the typed-DTO submodules
    ({!Dto.Order}, {!Dto.Trade}) can depend on it
    without creating a wrapper-to-sibling cycle. *)

open Core

let rec decimal_of_json : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | `Assoc fields as j -> (
      match List.assoc_opt "value" fields with
      | Some v -> (
          let base = decimal_of_json v in
          (* Optional proto-style { value, scale }: divide by 10^scale. *)
          match List.assoc_opt "scale" fields with
          | Some (`Int 0) | None -> base
          | Some (`Int k) when k > 0 ->
              let rec pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1) in
              Decimal.div base (Decimal.of_int (pow10 k))
          | _ -> base)
      | None ->
          invalid_arg
            ("Finam DTO: decimal object without value: " ^ Yojson.Safe.to_string j))
  | `Null -> Decimal.zero
  | j -> invalid_arg ("Finam DTO: not a decimal: " ^ Yojson.Safe.to_string j)

(** Tries a sequence of candidate field names, returning the first one
    that's present and non-null. Makes the decoder tolerant of the
    gRPC→REST bridge relabeling fields (volume vs vol vs v, etc.). *)
let decimal_field_any ?(required = true) j candidates =
  let rec loop = function
    | [] ->
        if required then
          invalid_arg ("Finam DTO: missing decimal field " ^ String.concat "/" candidates)
        else Decimal.zero
    | k :: rest -> (
        match Yojson.Safe.Util.member k j with
        | `Null -> loop rest
        | v -> ( try decimal_of_json v with _ -> loop rest))
  in
  loop candidates

let decimal_field k j = decimal_field_any j [ k ]

(** --- Finam wire-format enum converters (gRPC convention) --- *)

let finam_kind_to_wire : Broker_domain.Order.kind -> string = function
  | Market -> "ORDER_TYPE_MARKET"
  | Limit _ -> "ORDER_TYPE_LIMIT"
  | Stop _ -> "ORDER_TYPE_STOP"
  | Stop_limit _ -> "ORDER_TYPE_STOP_LIMIT"

let finam_kind_of_wire s price_fn =
  match s with
  | "ORDER_TYPE_LIMIT" -> Broker_domain.Order.Limit (price_fn "limit_price")
  | "ORDER_TYPE_STOP" -> Stop (price_fn "stop_price")
  | "ORDER_TYPE_STOP_LIMIT" ->
      Stop_limit { stop = price_fn "stop_price"; limit = price_fn "limit_price" }
  | _ -> Market

let finam_tif_to_wire : Broker_domain.Order.time_in_force -> string = function
  | DAY -> "TIME_IN_FORCE_DAY"
  | GTC -> "TIME_IN_FORCE_GOOD_TILL_CANCEL"
  | IOC -> "TIME_IN_FORCE_IOC"
  | FOK -> "TIME_IN_FORCE_FOK"

let finam_tif_of_wire = function
  | "TIME_IN_FORCE_GOOD_TILL_CANCEL" -> Broker_domain.Order.GTC
  | "TIME_IN_FORCE_IOC" -> IOC
  | "TIME_IN_FORCE_FOK" -> FOK
  | _ -> DAY

let finam_side_to_wire : Side.t -> string = function
  | Buy -> "SIDE_BUY"
  | Sell -> "SIDE_SELL"

let finam_side_of_wire = function
  | "SIDE_SELL" -> Side.Sell
  | _ -> Buy

let finam_status_of_wire = function
  | "ORDER_STATUS_NEW" -> Broker_domain.Order.New
  | "ORDER_STATUS_PARTIALLY_FILLED" -> Partially_filled
  | "ORDER_STATUS_FILLED" -> Filled
  | "ORDER_STATUS_CANCELED" -> Cancelled
  | "ORDER_STATUS_REJECTED"
  | "ORDER_STATUS_REJECTED_BY_EXCHANGE"
  | "ORDER_STATUS_DENIED_BY_BROKER" -> Rejected
  | "ORDER_STATUS_EXPIRED" -> Expired
  | "ORDER_STATUS_PENDING_CANCEL" -> Pending_cancel
  | "ORDER_STATUS_PENDING_NEW" -> Pending_new
  | "ORDER_STATUS_SUSPENDED" -> Suspended
  | "ORDER_STATUS_FAILED" -> Failed
  | _ -> New

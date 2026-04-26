(** Finam wire DTOs: decode JSON payloads into domain types.
    This module isolates wire-format concerns from the rest of the system,
    so a switch from REST → gRPC only touches this file. *)

open Core

(** A raw-sample sink that the caller can set from outside to capture
    unexpected response shapes for debugging. When non-[None], the
    candle decoder prints the first raw bar it sees to stderr (once
    per process) so a single failing request makes the real payload
    visible without guessing. *)
let debug_sample_logged = ref false

let debug_log_sample ?(label = "bar") (j : Yojson.Safe.t) : unit =
  if not !debug_sample_logged then begin
    debug_sample_logged := true;
    Log.debug "[finam dto] sample %s: %s" label (Yojson.Safe.to_string j)
  end

(** Decode a decimal-ish field tolerantly.
    Accepts all of:
      - "1.23"
      - 123
      - 1.23
      - { "value": "1.23" }  (gRPC Decimal wrapper)
      - { "value": "123", "scale": 2 }  (proto Money-style: val / 10^scale)
      - absent / null → 0 (callers decide if that's a problem)

    When a lookup under [names] hits a truly unknown shape, raises
    [Invalid_argument] with the field name; used for required fields. *)
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

let candle_of_json j : Candle.t =
  (* On the first decode, log the raw shape so we can see what the
     server actually sends without adding an ad-hoc debug flag. *)
  debug_log_sample ~label:"bar" j;
  let ts =
    match Yojson.Safe.Util.member "timestamp" j with
    | `String s -> Infra_common.Iso8601.parse s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | `Null -> (
        (* Alternative common names: 'time', 't'. *)
        match Yojson.Safe.Util.member "time" j with
        | `String s -> Infra_common.Iso8601.parse s
        | `Int n -> Int64.of_int n
        | _ -> 0L)
    | _ -> 0L
  in
  (* Per-field candidate lists: first match wins. Volume is the one that
     notoriously varies between gRPC transcoders. *)
  let open_ = decimal_field_any j [ "open"; "o" ] in
  let high = decimal_field_any j [ "high"; "h" ] in
  let low = decimal_field_any j [ "low"; "l" ] in
  let close = decimal_field_any j [ "close"; "c" ] in
  let volume =
    decimal_field_any ~required:false j
      [ "volume"; "vol"; "v"; "total_volume"; "trading_volume" ]
  in
  Candle.make ~ts ~open_ ~high ~low ~close ~volume

(** Decode Finam's [GetAssetResponse] (proto field set: board, id,
    ticker, mic, isin, type, name, decimals, min_step, lot_size,
    quote_currency, asset_details).

    We keep only what {!Instrument} needs: ticker, mic, optional
    isin, optional board. The rest (decimals, lot_size, …) is
    instrument *metadata* — out of scope for identity.

    Defensive: ISIN is optional in the wire payload (futures often
    don't have one), and we silently drop invalid ISINs (length /
    checksum) instead of failing the whole decode — the instrument is
    still usable without it. *)
let instrument_of_asset_json (j : Yojson.Safe.t) : Instrument.t =
  let open Yojson.Safe.Util in
  let str_opt k =
    match member k j with
    | `String "" | `Null -> None
    | `String s -> Some s
    | _ -> None
  in
  let req_str k =
    match str_opt k with
    | Some s -> s
    | None -> invalid_arg ("Finam DTO asset: missing string field " ^ k)
  in
  let ticker = Ticker.of_string (req_str "ticker") in
  let venue = Mic.of_string (req_str "mic") in
  let isin =
    match str_opt "isin" with
    | None -> None
    | Some s -> ( try Some (Isin.of_string s) with Invalid_argument _ -> None)
  in
  let board =
    match str_opt "board" with
    | None -> None
    | Some s -> ( try Some (Board.of_string s) with Invalid_argument _ -> None)
  in
  Instrument.make ~ticker ~venue ?isin ?board ()

(** --- Finam wire-format enum converters (gRPC convention) --- *)

let finam_kind_to_wire : Order.kind -> string = function
  | Market -> "ORDER_TYPE_MARKET"
  | Limit _ -> "ORDER_TYPE_LIMIT"
  | Stop _ -> "ORDER_TYPE_STOP"
  | Stop_limit _ -> "ORDER_TYPE_STOP_LIMIT"

let finam_kind_of_wire s price_fn =
  match s with
  | "ORDER_TYPE_LIMIT" -> Order.Limit (price_fn "limit_price")
  | "ORDER_TYPE_STOP" -> Stop (price_fn "stop_price")
  | "ORDER_TYPE_STOP_LIMIT" ->
      Stop_limit { stop = price_fn "stop_price"; limit = price_fn "limit_price" }
  | _ -> Market

let finam_tif_to_wire : Order.time_in_force -> string = function
  | DAY -> "TIME_IN_FORCE_DAY"
  | GTC -> "TIME_IN_FORCE_GOOD_TILL_CANCEL"
  | IOC -> "TIME_IN_FORCE_IOC"
  | FOK -> "TIME_IN_FORCE_FOK"

let finam_tif_of_wire = function
  | "TIME_IN_FORCE_GOOD_TILL_CANCEL" -> Order.GTC
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
  | "ORDER_STATUS_NEW" -> Order.New
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

(** --- Order DTO: encode PlaceOrder body and decode OrderState response --- *)

(** Build the JSON body for [POST /v1/accounts/{id}/orders].
    Prices and quantities use the [{"value": "..."}] wrapper Finam
    requires on the wire (protobuf [google.type.Decimal]). *)
let place_order_payload
    ~(instrument : Instrument.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(kind : Order.kind)
    ~(tif : Order.time_in_force)
    ?client_order_id
    () : Yojson.Safe.t =
  let w = Acl_common.Decimal_wire.yojson_of_t_wrapped in
  let price_fields =
    match kind with
    | Market -> []
    | Limit p -> [ ("limit_price", w p) ]
    | Stop p -> [ ("stop_price", w p) ]
    | Stop_limit { stop; limit } -> [ ("limit_price", w limit); ("stop_price", w stop) ]
  in
  let coid =
    match client_order_id with
    | None -> []
    | Some id -> [ ("client_order_id", `String id) ]
  in
  `Assoc
    ([
       ("symbol", `String (Routing.qualify_instrument instrument));
       ("quantity", w quantity);
       ("side", `String (finam_side_to_wire side));
       ("type", `String (finam_kind_to_wire kind));
       ("time_in_force", `String (finam_tif_to_wire tif));
     ]
    @ price_fields @ coid)

(** Decode a single Finam [OrderState] JSON (returned by GetOrder,
    PlaceOrder, and as array elements in GetOrders). The nested
    [order] object carries the original request parameters;
    top-level fields carry execution state. *)
let order_of_json (j : Yojson.Safe.t) : Order.t =
  let open Yojson.Safe.Util in
  let str k =
    match member k j with
    | `String s -> s
    | _ -> ""
  in
  let inner = member "order" j in
  let inner_str k =
    match member k inner with
    | `String s -> s
    | _ -> ""
  in
  let dec k obj = try decimal_of_json (member k obj) with _ -> Decimal.zero in
  let instrument =
    try Instrument.of_qualified (inner_str "symbol")
    with _ ->
      Instrument.make ~ticker:(Ticker.of_string "UNKNOWN") ~venue:(Mic.of_string "XXXX")
        ()
  in
  let price_fn field_name = dec field_name inner in
  let kind = finam_kind_of_wire (inner_str "type") price_fn in
  let tif = finam_tif_of_wire (inner_str "time_in_force") in
  let side = finam_side_of_wire (inner_str "side") in
  let status = finam_status_of_wire (str "status") in
  let created_ts =
    match member "transact_at" j with
    | `String s -> Infra_common.Iso8601.parse s
    | _ -> 0L
  in
  {
    Order.id = str "order_id";
    exec_id = str "exec_id";
    instrument;
    side;
    quantity = dec "initial_quantity" j;
    filled = dec "executed_quantity" j;
    remaining = dec "remaining_quantity" j;
    kind;
    tif;
    status;
    created_ts;
    client_order_id = inner_str "client_order_id";
  }

let orders_of_json (j : Yojson.Safe.t) : Order.t list =
  let open Yojson.Safe.Util in
  match member "orders" j with
  | `List items -> List.map order_of_json items
  | _ -> []

type account_trade = { order_id : string; execution : Order.execution }
(** Per-trade record from [GET /v1/accounts/{account_id}/trades].
    Shape (from the Finam swagger's [v1AccountTrade]):
    {v
    { "trade_id": "...",
      "order_id": "...",
      "price": typeDecimal,
      "size": typeDecimal,
      "side": "SIDE_BUY" | "SIDE_SELL",
      "timestamp": "2026-04-18T10:00:00Z" }
    v}
    Finam's trade payload does not currently carry a per-trade
    fee field; we default to zero. If commission becomes needed
    for accurate reconcile P&L, fetch from the order state and
    prorate by fill quantity. Returns the parent [order_id] so
    the caller can filter to the trades relevant to their
    [client_order_id]. *)

let account_trade_of_json (j : Yojson.Safe.t) : account_trade =
  let open Yojson.Safe.Util in
  let str k =
    match member k j with
    | `String s -> s
    | _ -> ""
  in
  let dec k = try decimal_of_json (member k j) with _ -> Decimal.zero in
  let ts =
    match member "timestamp" j with
    | `String s -> Infra_common.Iso8601.parse s
    | _ -> 0L
  in
  {
    order_id = str "order_id";
    execution = { ts; quantity = dec "size"; price = dec "price"; fee = Decimal.zero };
  }

let account_trades_of_json (j : Yojson.Safe.t) : account_trade list =
  let open Yojson.Safe.Util in
  match member "trades" j with
  | `List items -> List.map account_trade_of_json items
  | _ -> []

let candles_of_json j : Candle.t list =
  let arr =
    match Yojson.Safe.Util.member "bars" j with
    | `List l -> l
    | _ -> (
        match Yojson.Safe.Util.member "candles" j with
        | `List l -> l
        | `Null -> (
            (* Some gRPC bridges wrap the payload under "result": { "bars": [...] }. *)
            match Yojson.Safe.Util.member "result" j with
            | `Assoc _ as inner -> (
                match Yojson.Safe.Util.member "bars" inner with
                | `List l -> l
                | _ -> [])
            | _ -> [])
        | _ -> [])
  in
  List.map candle_of_json arr

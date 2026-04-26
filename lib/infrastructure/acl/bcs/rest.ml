(** BCS REST client.
    Auth (Keycloak refresh_token → access_token) is handled by [Auth];
    consumers call business methods and the cached JWT is slipped into
    [Authorization: Bearer …] transparently. *)

open Core

type t = { transport : Http_transport.t; cfg : Config.t; auth : Auth.t }

let make ~transport ~cfg ~token_store =
  let auth = Auth.make ~transport ~cfg ~token_store in
  { transport; cfg; auth }

let req_with_token ~meth ~url ~body ~token : Http_transport.request =
  (* BCS requires an explicit [Content-Type: application/json] whenever
     the request carries a body; without it the BFF returns 415 with
     "Content-Type 'application/octet-stream' is not supported". *)
  let base = [ ("Authorization", "Bearer " ^ token); ("Accept", "application/json") ] in
  let headers =
    match body with
    | Some _ -> ("Content-Type", "application/json") :: base
    | None -> base
  in
  { meth; url; headers; body }

(** Send a request carrying the current access_token; on 401
    invalidate and retry exactly once (shared retry logic with
    [Finam.Rest]). *)
let send_with_auth_retry (t : t) ~meth ~url ~body =
  Http_transport.with_auth_retry t.transport
    ~get_token:(fun () -> Auth.current t.auth)
    ~invalidate:(fun () -> Auth.invalidate t.auth)
    ~build_request:(fun ~token -> req_with_token ~meth ~url ~body ~token)

let get_json t path query : Yojson.Safe.t =
  let base = t.cfg.Config.rest_base in
  let url = Uri.with_path base (Uri.path base ^ path) in
  let url = Uri.with_query' url query in
  let resp = send_with_auth_retry t ~meth:`GET ~url ~body:None in
  if resp.status < 200 || resp.status >= 300 then
    failwith
      (Printf.sprintf "BCS REST %d on %s: %s" resp.status (Uri.to_string url) resp.body);
  Yojson.Safe.from_string resp.body

(** RFC 3339 / ISO 8601 UTC with millisecond precision. BCS emits
    millis on responses; send the same shape for consistency. *)
let iso8601_of_ts (ts : int64) : string =
  let tm = Unix.gmtime (Int64.to_float ts) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.000Z" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

(** BCS timeframe enum, confirmed from the docs' swagger dropdown:
    `M1 M5 M15 M30 H1 H4 D W MN`. Note the daily/weekly/monthly codes
    drop the `1` suffix our internal enum carries. *)
let timeframe_wire : Timeframe.t -> string = function
  | M1 -> "M1"
  | M5 -> "M5"
  | M15 -> "M15"
  | M30 -> "M30"
  | H1 -> "H1"
  | H4 -> "H4"
  | D1 -> "D"
  | W1 -> "W"
  | MN1 -> "MN"

(** Resolve an [Instrument.t] to BCS's (ticker, classCode) pair.
    Uses [Instrument.board] when present, otherwise falls back to
    [Config.default_class_code]. The instrument's [venue] (MIC) is
    intentionally ignored — BCS routes by board, not by venue. *)
let route_instrument cfg (i : Instrument.t) : string * string =
  let ticker = Ticker.to_string (Instrument.ticker i) in
  let class_code =
    match Instrument.board i with
    | Some b -> Board.to_string b
    | None -> cfg.Config.default_class_code
  in
  (ticker, class_code)

(** Server-side cap on one response. The docs don't publish it, but the
    live endpoint replies with [CANDLE_LIMIT_EXCEEDED] at 1441+. *)
let max_bars_per_request = 1440

(** GET /trade-api-market-data-connector/api/v1/candles-chart?…
    BCS returns bars newest-first; we sort by ts ascending so consumers
    (indicators, strategies, backtester) see the chronological order
    they expect. The request window is capped at [max_bars_per_request]
    bars regardless of [n], so [bars ~n:10_000] transparently asks for
    the most-recent 1440 and the caller is responsible for stitching
    if they need more (paginating isn't supported yet). *)
let bars ?from_ts ?to_ts ?(n = 500) (t : t) ~instrument ~timeframe : Candle.t list =
  let ticker, class_code = route_instrument t.cfg instrument in
  let n = min n max_bars_per_request in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let tf_secs = Int64.of_int (Timeframe.to_seconds timeframe) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts ~default:(Int64.sub end_ts (Int64.mul (Int64.of_int n) tf_secs))
  in
  let query =
    [
      ("classCode", class_code);
      ("ticker", ticker);
      ("startDate", iso8601_of_ts start_ts);
      ("endDate", iso8601_of_ts end_ts);
      ("timeFrame", timeframe_wire timeframe);
    ]
  in
  let j = get_json t "/trade-api-market-data-connector/api/v1/candles-chart" query in
  let items =
    match Yojson.Safe.Util.member "bars" j with
    | `List l -> l
    | _ -> []
  in
  List.map Acl_common.Candle_wire.of_yojson_flex items
  |> List.sort (fun (a : Candle.t) b -> Int64.compare a.ts b.ts)

(** BCS doesn't expose a generic exchanges/venues endpoint that we've
    confirmed yet; return the standard MOEX boards as a static list.
    Users who need others can point [Config.default_class_code] at the
    right code directly. *)
let exchanges _t : Yojson.Safe.t =
  `Assoc
    [
      ( "exchanges",
        `List
          [
            `Assoc [ ("mic", `String "TQBR"); ("name", `String "MOEX — T+ stocks") ];
            `Assoc [ ("mic", `String "TQBS"); ("name", `String "MOEX — T+ ETF") ];
            `Assoc [ ("mic", `String "TQTF"); ("name", `String "MOEX — T+ FinEx") ];
            `Assoc [ ("mic", `String "TQOB"); ("name", `String "MOEX — T+ bonds") ];
            `Assoc [ ("mic", `String "SPBXM"); ("name", `String "SPB — foreign") ];
          ] );
    ]

(** --- Orders (trade-api-bff-operations) --- *)

let ops_path = "/trade-api-bff-operations/api/v1"

let post_json t path (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let base = t.cfg.Config.rest_base in
  let url = Uri.with_path base (Uri.path base ^ path) in
  let resp =
    send_with_auth_retry t ~meth:`POST ~url ~body:(Some (Yojson.Safe.to_string payload))
  in
  if resp.status < 200 || resp.status >= 300 then
    failwith
      (Printf.sprintf "BCS REST %d on %s: %s" resp.status (Uri.to_string url) resp.body);
  Yojson.Safe.from_string resp.body

(** BCS status strings → domain [Order.status]. BCS sends plain
    strings like ["NEW"], ["FILLED"], ["CANCELED"]. *)
let bcs_status_of_wire = function
  | "NEW" -> Order.New
  | "PARTIALLY_FILLED" -> Partially_filled
  | "FILLED" -> Filled
  | "CANCELED" | "CANCELLED" -> Cancelled
  | "REJECTED" -> Rejected
  | "EXPIRED" -> Expired
  | "PENDING_CANCEL" -> Pending_cancel
  | "PENDING_NEW" -> Pending_new
  | "SUSPENDED" -> Suspended
  | "FAILED" -> Failed
  | _ -> New

(** BCS side enum: ["1"] = buy, ["2"] = sell. *)
let bcs_side_of (s : Side.t) : string =
  match s with
  | Buy -> "1"
  | Sell -> "2"

let bcs_side_to (s : string) : Side.t =
  match s with
  | "1" -> Buy
  | "2" -> Sell
  | _ -> Buy

(** BCS order type enum: ["1"] = market, ["2"] = limit. *)
let bcs_order_type_of (k : Order.kind) : string =
  match k with
  | Market -> "1"
  | Limit _ | Stop _ | Stop_limit _ -> "2"

(** Decode a single BCS [OrderStatus] JSON into [Order.t]. *)
let bcs_order_of_json cfg (j : Yojson.Safe.t) : Order.t =
  let open Yojson.Safe.Util in
  let str k =
    match member k j with
    | `String s -> s
    | _ -> ""
  in
  let int_d k =
    match member k j with
    | `Int n -> Decimal.of_int n
    | `Float f -> Decimal.of_float f
    | _ -> Decimal.zero
  in
  let float_d k =
    match member k j with
    | `Float f -> Decimal.of_float f
    | `Int n -> Decimal.of_int n
    | _ -> Decimal.zero
  in
  let ticker = str "ticker" in
  let class_code = str "classCode" in
  let instrument =
    Instrument.make
      ~ticker:(Ticker.of_string (if ticker = "" then "UNKNOWN" else ticker))
      ~venue:(Mic.of_string "MISX")
      ~board:
        (Board.of_string
           (if class_code = "" then cfg.Config.default_class_code else class_code))
      ()
  in
  let price = float_d "price" in
  let kind =
    match str "orderType" with
    | "2" -> Order.Limit price
    | _ -> Market
  in
  let ts =
    match member "createdAt" j with
    | `String s -> Infra_common.Iso8601.parse s
    | _ -> 0L
  in
  {
    Order.id = str "clientOrderId";
    exec_id = str "exchangeId";
    instrument;
    side = bcs_side_to (str "side");
    quantity = int_d "orderQuantity";
    filled = int_d "filledQuantity";
    remaining = Decimal.sub (int_d "orderQuantity") (int_d "filledQuantity");
    kind;
    tif = Order.DAY;
    status =
      bcs_status_of_wire
        (match str "status" with
        | "" -> "NEW"
        | s -> String.uppercase_ascii s);
    created_ts = ts;
    client_order_id = str "clientOrderId";
  }

(** POST /trade-api-bff-operations/api/v1/orders — create order. *)
let create_order
    t
    ~(instrument : Instrument.t)
    ~(side : Side.t)
    ~(quantity : int)
    ~(kind : Order.kind)
    ~client_order_id
    () : Order.t =
  let ticker, class_code = route_instrument t.cfg instrument in
  let price_field =
    match kind with
    | Market -> []
    | Limit p -> [ ("price", `Float (Decimal.to_float p)) ]
    | Stop p -> [ ("price", `Float (Decimal.to_float p)) ]
    | Stop_limit { limit; _ } -> [ ("price", `Float (Decimal.to_float limit)) ]
  in
  let payload : Yojson.Safe.t =
    `Assoc
      ([
         ("clientOrderId", `String client_order_id);
         ("side", `String (bcs_side_of side));
         ("orderType", `String (bcs_order_type_of kind));
         ("orderQuantity", `Int quantity);
         ("ticker", `String ticker);
         ("classCode", `String class_code);
       ]
      @ price_field)
  in
  let j = post_json t (ops_path ^ "/orders") payload in
  (* BCS create returns just {clientOrderId, status}; build a minimal
     Order.t from the request params + response. *)
  let open Yojson.Safe.Util in
  let status_str =
    match member "status" j with
    | `String s -> s
    | _ -> "NEW"
  in
  {
    Order.id = client_order_id;
    exec_id = "";
    instrument;
    side;
    quantity = Decimal.of_int quantity;
    filled = Decimal.zero;
    remaining = Decimal.of_int quantity;
    kind;
    tif = DAY;
    status = bcs_status_of_wire (String.uppercase_ascii status_str);
    created_ts = Int64.of_float (Unix.gettimeofday ());
    client_order_id;
  }

(** POST /trade-api-bff-order-details/api/v1/orders/search —
    list/query orders. BCS splits reads from writes across two BFFs
    (CQRS-style): creation/edit/cancel live in
    [trade-api-bff-operations], but historical queries go through
    [trade-api-bff-order-details] with a POST body carrying filters:
    required [startDateTime]/[endDateTime] plus optional
    [side]/[orderStatus]/[orderTypes]/[tickers]/[classCodes]. Empty
    filter arrays match all.

    Optional [from_ts]/[to_ts] override the default window. The
    default covers 30 days ending "now" — enough for reconcile
    (which wants live orders) but short enough to keep payloads
    small on accounts with years of history. *)
let get_orders ?from_ts ?to_ts t : Order.t list =
  let base = t.cfg.Config.rest_base in
  let path = "/trade-api-bff-order-details/api/v1/orders/search" in
  let url = Uri.with_path base (Uri.path base ^ path) in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts ~default:(Int64.sub end_ts (Int64.mul 30L 86_400L))
  in
  let body : Yojson.Safe.t =
    `Assoc
      [
        ("startDateTime", `String (iso8601_of_ts start_ts));
        ("endDateTime", `String (iso8601_of_ts end_ts));
        ("orderStatus", `List []);
        ("orderTypes", `List []);
        ("tickers", `List []);
        ("classCodes", `List []);
      ]
  in
  let resp =
    send_with_auth_retry t ~meth:`POST ~url ~body:(Some (Yojson.Safe.to_string body))
  in
  if resp.status < 200 || resp.status >= 300 then
    failwith
      (Printf.sprintf "BCS REST %d on %s: %s" resp.status (Uri.to_string url) resp.body);
  let j = Yojson.Safe.from_string resp.body in
  let open Yojson.Safe.Util in
  (* Response shape unconfirmed. Try paginated [records] first (same
     wrapper as /deals), then legacy [orders], then bare array. *)
  let items =
    match member "records" j with
    | `List l -> l
    | _ -> (
        match member "orders" j with
        | `List l -> l
        | _ -> (
            match j with
            | `List l -> l
            | _ -> []))
  in
  List.map (bcs_order_of_json t.cfg) items

(** GET /trade-api-bff-operations/api/v1/orders/{id} — single order status. *)
let get_order t ~client_order_id : Order.t =
  let path = ops_path ^ "/orders/" ^ client_order_id in
  bcs_order_of_json t.cfg (get_json t path [])

(** POST /trade-api-bff-operations/api/v1/orders/{cid} — edit qty/price.
    Same pattern as cancel: URL path names the order being modified,
    body carries a fresh [clientOrderId] that BCS uses to dedupe
    retries of this edit operation. *)
let edit_order t ~client_order_id ?quantity ?price () : Order.t =
  let path = ops_path ^ "/orders/" ^ client_order_id in
  let edit_cid = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  let fields =
    [ ("clientOrderId", `String edit_cid) ]
    @ (match quantity with
      | Some q -> [ ("orderQuantity", `Int q) ]
      | None -> [])
    @
    match price with
    | Some p -> [ ("price", `Float (Decimal.to_float p)) ]
    | None -> []
  in
  let j = post_json t path (`Assoc fields) in
  let open Yojson.Safe.Util in
  let status_str =
    match member "status" j with
    | `String s -> s
    | _ -> "NEW"
  in
  {
    Order.id = client_order_id;
    exec_id = "";
    instrument =
      Instrument.make ~ticker:(Ticker.of_string "UNKNOWN") ~venue:(Mic.of_string "MISX")
        ();
    side = Buy;
    quantity =
      (match quantity with
      | Some q -> Decimal.of_int q
      | None -> Decimal.zero);
    filled = Decimal.zero;
    remaining =
      (match quantity with
      | Some q -> Decimal.of_int q
      | None -> Decimal.zero);
    kind =
      (match price with
      | Some p -> Order.Limit p
      | None -> Market);
    tif = DAY;
    status = bcs_status_of_wire status_str;
    created_ts = 0L;
    client_order_id;
  }

(** Decode one record from the BCS Deals payload into a
    (order_num, execution) pair. Field shape per official BCS docs
    (paginated retail API):

    - [orderNum] int64       broker order number (correlates with
                             [exec_id] on the parent [Order.t])
    - [tradeNum] int64       deal/execution id (informational, unused)
    - [clientCode] string    client account code (not an order id)
    - [ticker], [classCode]  instrument identity
    - [side] string "1"/"2"  BUY/SELL
    - [tradeDateTime]        execution timestamp (RFC 3339)
    - [price] double         execution price
    - [tradeQuantity] double size in shares/contracts
    - [tradeQuantityLots]    size in lots (ignored — lots↔shares is
                             instrument-dependent; we keep qty in
                             shares for domain consistency)
    - [volume], [go], [contractAmount], [settleDate], [...]
                             additional fields outside the domain model

    Unlike the tigusigalpa Go client (which exposed a [clientOrderId]
    field on deals), the real BCS payload carries only [orderNum], so
    the broker adapter must first resolve [client_order_id → exec_id]
    via [get_order] before filtering this list.

    No per-fill commission field — [fee] defaults to zero; fees live
    on the parent [Order] state, not per-execution. *)
let bcs_execution_of_json (j : Yojson.Safe.t) : string * Order.execution =
  let open Yojson.Safe.Util in
  let int_or_str k =
    match member k j with
    | `String s -> s
    | `Int n -> string_of_int n
    | `Intlit s -> s
    | _ -> ""
  in
  let float_d k =
    match member k j with
    | `Float f -> Decimal.of_float f
    | `Int n -> Decimal.of_int n
    | `Intlit s -> Decimal.of_float (float_of_string s)
    | _ -> Decimal.zero
  in
  let ts =
    match member "tradeDateTime" j with
    | `String s -> Infra_common.Iso8601.parse s
    | _ -> 0L
  in
  ( int_or_str "orderNum",
    {
      Order.ts;
      quantity = float_d "tradeQuantity";
      price = float_d "price";
      fee = Decimal.zero;
    } )

(** POST /trade-api-bff-trade-details/api/v1/trades/search —
    paginated account-wide executions ("deals" in Russian broker
    parlance, "trades" in BCS's URL). Yet another BFF — reads live
    under [trade-api-bff-trade-details], separate from both
    [-operations] and [-order-details]. Filters in the body mirror
    the orders-search shape: required [startDateTime]/[endDateTime]
    plus optional [side]/[tradeNums]/[tickers]/[classCodes]. Empty
    arrays match all.

    Default window = 30 days ending "now", same rationale as
    [get_orders]. *)
let get_deals ?from_ts ?to_ts t : (string * Order.execution) list =
  let base = t.cfg.Config.rest_base in
  let path = "/trade-api-bff-trade-details/api/v1/trades/search" in
  let url = Uri.with_path base (Uri.path base ^ path) in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts ~default:(Int64.sub end_ts (Int64.mul 30L 86_400L))
  in
  let body : Yojson.Safe.t =
    `Assoc
      [
        ("startDateTime", `String (iso8601_of_ts start_ts));
        ("endDateTime", `String (iso8601_of_ts end_ts));
        ("tradeNums", `List []);
        ("tickers", `List []);
        ("classCodes", `List []);
      ]
  in
  let resp =
    send_with_auth_retry t ~meth:`POST ~url ~body:(Some (Yojson.Safe.to_string body))
  in
  if resp.status < 200 || resp.status >= 300 then
    failwith
      (Printf.sprintf "BCS REST %d on %s: %s" resp.status (Uri.to_string url) resp.body);
  let j = Yojson.Safe.from_string resp.body in
  let open Yojson.Safe.Util in
  let items =
    match member "records" j with
    | `List l -> l
    | _ -> (
        match j with
        | `List l -> l
        | _ -> [])
  in
  List.map bcs_execution_of_json items

(** POST /trade-api-bff-operations/api/v1/orders/{cid}/cancel — cancel.
    BCS models cancellation as its own idempotent POST: the URL path
    names the order being cancelled (its original [clientOrderId]),
    and the body carries a fresh [clientOrderId] identifying *this
    cancel operation* (so BCS can dedupe retries of a cancel the
    same way it dedupes retries of a create). We generate that UUID
    per call — it's opaque to callers and not surfaced on [Order.t];
    stable-across-retries idempotency is a higher-layer concern and
    we don't retry POSTs at the HTTP transport level. *)
let cancel_order t ~client_order_id : Order.t =
  let path = ops_path ^ "/orders/" ^ client_order_id ^ "/cancel" in
  let cancel_cid = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  let payload : Yojson.Safe.t = `Assoc [ ("clientOrderId", `String cancel_cid) ] in
  let j = post_json t path payload in
  let open Yojson.Safe.Util in
  let status_str =
    match member "status" j with
    | `String s -> s
    | _ -> "CANCELLED"
  in
  {
    Order.id = client_order_id;
    exec_id = "";
    instrument =
      Instrument.make ~ticker:(Ticker.of_string "UNKNOWN") ~venue:(Mic.of_string "MISX")
        ();
    side = Buy;
    quantity = Decimal.zero;
    filled = Decimal.zero;
    remaining = Decimal.zero;
    kind = Market;
    tif = DAY;
    status = bcs_status_of_wire (String.uppercase_ascii status_str);
    created_ts = 0L;
    client_order_id;
  }

(** Accessors for [Ws_bridge] to share auth state and config. *)
let auth t = t.auth

let cfg t = t.cfg

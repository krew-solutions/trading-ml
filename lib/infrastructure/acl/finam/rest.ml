(** Finam Trade REST client.
    Uses a pluggable [Http_transport.t] so the module is pure and testable;
    production wires in cohttp-eio, tests wire in an in-memory fake.

    Authentication is transparent: the client owns a [Auth.t] cache, and
    every request resolves a fresh JWT via [Auth.current] right before
    sending. The caller only provides the long-lived secret in [Config.t].
    On 401 we refresh once and retry — covers the race where the server
    invalidates the JWT slightly before our clock expects. *)

open Core

type t = { transport : Http_transport.t; cfg : Config.t; auth : Auth.t }

let make ~transport ~cfg =
  let auth = Auth.make ~secret:cfg.Config.secret ~transport ~base:cfg.rest_base in
  { transport; cfg; auth }

let auth_headers t =
  [
    ("Authorization", "Bearer " ^ Auth.current t.auth);
    ("Accept", "application/json");
    ("Content-Type", "application/json");
  ]

let url cfg path query =
  let base = cfg.Config.rest_base in
  let u = Uri.with_path base (Uri.path base ^ path) in
  Uri.with_query' u query

let ensure_ok (resp : Http_transport.response) =
  if resp.status >= 200 && resp.status < 300 then resp.body
  else failwith (Printf.sprintf "Finam REST %d: %s" resp.status resp.body)

let req_with_token ~meth ~url ~body ~token : Http_transport.request =
  {
    meth;
    url;
    headers =
      [
        ("Authorization", "Bearer " ^ token);
        ("Accept", "application/json");
        ("Content-Type", "application/json");
      ];
    body;
  }

(** Send a request carrying the current JWT; on 401 invalidate and
    retry exactly once. The retry logic is shared with [Bcs.Rest] via
    [Http_transport.with_auth_retry]. *)
let send_with_auth_retry (t : t) ~meth ~url ~body =
  Http_transport.with_auth_retry t.transport
    ~get_token:(fun () -> Auth.current t.auth)
    ~invalidate:(fun () -> Auth.invalidate t.auth)
    ~build_request:(fun ~token -> req_with_token ~meth ~url ~body ~token)

let _ = auth_headers

let get_json t path query : Yojson.Safe.t =
  let u = url t.cfg path query in
  let resp = send_with_auth_retry t ~meth:`GET ~url:u ~body:None in
  Yojson.Safe.from_string (ensure_ok resp)

let post_json t path (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let u = url t.cfg path [] in
  let resp =
    send_with_auth_retry t ~meth:`POST ~url:u ~body:(Some (Yojson.Safe.to_string payload))
  in
  Yojson.Safe.from_string (ensure_ok resp)

let delete t path =
  let u = url t.cfg path [] in
  let resp = send_with_auth_retry t ~meth:`DELETE ~url:u ~body:None in
  ignore (ensure_ok resp)

let qualify_instrument = Routing.qualify_instrument

(** Finam gRPC TimeFrame enum mapping. Kept here, not in [Core.Timeframe],
    so the core type stays broker-agnostic. *)
let timeframe_wire : Timeframe.t -> string = function
  | M1 -> "TIME_FRAME_M1"
  | M5 -> "TIME_FRAME_M5"
  | M15 -> "TIME_FRAME_M15"
  | M30 -> "TIME_FRAME_M30"
  | H1 -> "TIME_FRAME_H1"
  | H4 -> "TIME_FRAME_H4"
  | D1 -> "TIME_FRAME_D"
  | W1 -> "TIME_FRAME_W"
  | MN1 -> "TIME_FRAME_MN"

(** Format a unix-epoch timestamp as RFC 3339 / ISO 8601 (UTC, "Z"
    suffix). Finam's new REST expects the bars endpoint's
    [interval.start_time] / [end_time] in this shape; plain int
    seconds are rejected as INVALID_ARGUMENT. *)
let iso8601_of_ts (ts : int64) : string =
  let tm = Unix.gmtime (Int64.to_float ts) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

(** GET /v1/instruments/{symbol@mic}/bars?timeframe=...&interval.start_time=...&interval.end_time=...
    All three query params are required. When the caller doesn't pass
    [from_ts] / [to_ts] we default to a window of [n] timeframe units
    ending at "now", so [bars ~n:500 ~timeframe:H1] returns the last
    500 hourly bars. *)
let bars ?from_ts ?to_ts ?(n = 500) (t : t) ~instrument ~timeframe : Candle.t list =
  let path = Printf.sprintf "/v1/instruments/%s/bars" (qualify_instrument instrument) in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let tf_secs = Int64.of_int (Timeframe.to_seconds timeframe) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts ~default:(Int64.sub end_ts (Int64.mul (Int64.of_int n) tf_secs))
  in
  let q =
    [
      ("timeframe", timeframe_wire timeframe);
      ("interval.start_time", iso8601_of_ts start_ts);
      ("interval.end_time", iso8601_of_ts end_ts);
    ]
  in
  Dto.candles_of_json (get_json t path q)

(** GET /v1/assets/{symbol} — single instrument metadata.
    Returns an [Instrument.t] populated from the wire [Asset] payload
    (board, ticker, mic, isin). [symbol] is the qualified
    [TICKER@MIC] form; bare tickers get the configured
    [default_mic] appended via {!qualify_symbol}. *)
let get_asset t ~(instrument : Instrument.t) : Instrument.t =
  let path = Printf.sprintf "/v1/assets/%s" (qualify_instrument instrument) in
  Dto.instrument_of_asset_json (get_json t path [])

let account t ~account_id = get_json t (Printf.sprintf "/v1/accounts/%s" account_id) []

(** GET /v1/exchanges — list of venues with their MIC codes and labels. *)
let exchanges t : Yojson.Safe.t = get_json t "/v1/exchanges" []

(** GET /v1/accounts/{account_id}/orders — list all orders. *)
let get_orders t ~account_id : Order.t list =
  let path = Printf.sprintf "/v1/accounts/%s/orders" account_id in
  Dto.orders_of_json (get_json t path [])

(** GET /v1/accounts/{account_id}/orders/{order_id} — single order. *)
let get_order t ~account_id ~order_id : Order.t =
  let path = Printf.sprintf "/v1/accounts/%s/orders/%s" account_id order_id in
  Dto.order_of_json (get_json t path [])

(** POST /v1/accounts/{account_id}/orders — place a new order.
    Returns the server's order state (including the assigned
    [order_id] and initial [status]). *)
let place_order
    (t : t)
    ~account_id
    ~(instrument : Instrument.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(kind : Order.kind)
    ~(tif : Order.time_in_force)
    ?client_order_id
    () : Order.t =
  let path = Printf.sprintf "/v1/accounts/%s/orders" account_id in
  let payload =
    Dto.place_order_payload ~instrument ~side ~quantity ~kind ~tif ?client_order_id ()
  in
  Dto.order_of_json (post_json t path payload)

(** GET /v1/accounts/{account_id}/trades — account-wide execution
    history. Caller filters by [order_id] to get the executions
    for one specific order; Finam has no per-order trade endpoint.
    Returns records carrying their parent [order_id] so the
    filtering is client-side.

    Finam requires an explicit [interval.start_time] /
    [interval.end_time] window even though the docs call both
    optional — a 400 with code 3 is returned otherwise. Default
    window is the last 24 hours, which is what the live engine's
    reconcile loop needs; callers wanting historical backfill can
    pass [from_ts] / [to_ts] explicitly. *)
let get_trades ?from_ts ?to_ts t ~account_id : Dto.account_trade list =
  let path = Printf.sprintf "/v1/accounts/%s/trades" account_id in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts = Option.value from_ts ~default:(Int64.sub end_ts 86_400L) in
  let q =
    [
      ("interval.start_time", iso8601_of_ts start_ts);
      ("interval.end_time", iso8601_of_ts end_ts);
    ]
  in
  Dto.account_trades_of_json (get_json t path q)

(** DELETE /v1/accounts/{account_id}/orders/{order_id} — cancel. *)
let cancel_order t ~account_id ~order_id : Order.t =
  let path = Printf.sprintf "/v1/accounts/%s/orders/%s" account_id order_id in
  let resp = send_with_auth_retry t ~meth:`DELETE ~url:(url t.cfg path []) ~body:None in
  Dto.order_of_json (Yojson.Safe.from_string (ensure_ok resp))

(** Exposed for [Ws_bridge] so it can put the current JWT into the
    upgrade handshake's Authorization header. *)
let current_token t = Auth.current t.auth

(** Accessors for [Ws_bridge] to share auth state and config. *)
let auth t = t.auth

let cfg t = t.cfg

(** Finam Trade REST client.
    Uses a pluggable [Http_transport.t] so the module is pure and testable;
    production wires in cohttp-eio, tests wire in an in-memory fake.

    Authentication is transparent: the client owns a [Auth.t] cache, and
    every request resolves a fresh JWT via [Auth.current] right before
    sending. The caller only provides the long-lived secret in [Config.t].
    On 401 we refresh once and retry — covers the race where the server
    invalidates the JWT slightly before our clock expects. *)

open Core

type t = {
  transport : Http_transport.t;
  cfg : Config.t;
  auth : Auth.t;
}

let make ~transport ~cfg =
  let auth = Auth.make ~secret:cfg.Config.secret ~transport
               ~base:cfg.rest_base in
  { transport; cfg; auth }

let auth_headers t = [
  "Authorization", "Bearer " ^ Auth.current t.auth;
  "Accept", "application/json";
  "Content-Type", "application/json";
]

let url cfg path query =
  let base = cfg.Config.rest_base in
  let u = Uri.with_path base (Uri.path base ^ path) in
  Uri.with_query' u query

let ensure_ok (resp : Http_transport.response) =
  if resp.status >= 200 && resp.status < 300 then resp.body
  else failwith (Printf.sprintf "Finam REST %d: %s" resp.status resp.body)

let req_with_token ~meth ~url ~body ~token : Http_transport.request = {
  meth;
  url;
  headers = [
    "Authorization", "Bearer " ^ token;
    "Accept", "application/json";
    "Content-Type", "application/json";
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
    ~build_request:(fun ~token ->
      req_with_token ~meth ~url ~body ~token)

let _ = auth_headers

let get_json t path query : Yojson.Safe.t =
  let u = url t.cfg path query in
  let resp = send_with_auth_retry t ~meth:`GET ~url:u ~body:None in
  Yojson.Safe.from_string (ensure_ok resp)

let post_json t path (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let u = url t.cfg path [] in
  let resp = send_with_auth_retry t ~meth:`POST ~url:u
    ~body:(Some (Yojson.Safe.to_string payload)) in
  Yojson.Safe.from_string (ensure_ok resp)

let delete t path =
  let u = url t.cfg path [] in
  let resp = send_with_auth_retry t ~meth:`DELETE ~url:u ~body:None in
  ignore (ensure_ok resp)

(** Finam's new API expects symbols in [TICKER@MIC] form. When the
    caller passes a bare ticker we append the configured default MIC
    so RU-focused usage "just works" with e.g. [SBER]. *)
let qualify_symbol cfg (symbol : Symbol.t) =
  let s = Symbol.to_string symbol in
  if String.contains s '@' then s
  else match cfg.Config.default_mic with
    | Some mic -> s ^ "@" ^ mic
    | None -> s

(** Finam gRPC TimeFrame enum mapping. Kept here, not in [Core.Timeframe],
    so the core type stays broker-agnostic. *)
let timeframe_wire : Timeframe.t -> string = function
  | M1 -> "TIME_FRAME_M1" | M5 -> "TIME_FRAME_M5"
  | M15 -> "TIME_FRAME_M15" | M30 -> "TIME_FRAME_M30"
  | H1 -> "TIME_FRAME_H1" | H4 -> "TIME_FRAME_H4"
  | D1 -> "TIME_FRAME_D" | W1 -> "TIME_FRAME_W"
  | MN1 -> "TIME_FRAME_MN"

(** Format a unix-epoch timestamp as RFC 3339 / ISO 8601 (UTC, "Z"
    suffix). Finam's new REST expects the bars endpoint's
    [interval.start_time] / [end_time] in this shape; plain int
    seconds are rejected as INVALID_ARGUMENT. *)
let iso8601_of_ts (ts : int64) : string =
  let tm = Unix.gmtime (Int64.to_float ts) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** GET /v1/instruments/{symbol@mic}/bars?timeframe=...&interval.start_time=...&interval.end_time=...
    All three query params are required. When the caller doesn't pass
    [from_ts] / [to_ts] we default to a window of [n] timeframe units
    ending at "now", so [bars ~n:500 ~timeframe:H1] returns the last
    500 hourly bars. *)
let bars
    ?from_ts ?to_ts ?(n = 500)
    (t : t) ~symbol ~timeframe : Candle.t list =
  let path =
    Printf.sprintf "/v1/instruments/%s/bars" (qualify_symbol t.cfg symbol)
  in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let tf_secs = Int64.of_int (Timeframe.to_seconds timeframe) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts
      ~default:(Int64.sub end_ts (Int64.mul (Int64.of_int n) tf_secs))
  in
  let q = [
    "timeframe",            timeframe_wire timeframe;
    "interval.start_time",  iso8601_of_ts start_ts;
    "interval.end_time",    iso8601_of_ts end_ts;
  ] in
  Dto.candles_of_json (get_json t path q)

let account t ~account_id =
  get_json t (Printf.sprintf "/v1/accounts/%s" account_id) []

(** GET /v1/exchanges — list of venues with their MIC codes and labels. *)
let exchanges t : Yojson.Safe.t =
  get_json t "/v1/exchanges" []

let place_order
    (t : t)
    ~account_id
    ~(symbol : Symbol.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(kind : Order.kind)
    ~(tif : Order.time_in_force) : Yojson.Safe.t =
  let path = Printf.sprintf "/v1/accounts/%s/orders" account_id in
  let price_fields = match kind with
    | Market -> []
    | Limit p -> [ "limit_price", Decimal_json.yojson_of_t p ]
    | Stop p  -> [ "stop_price", Decimal_json.yojson_of_t p ]
    | Stop_limit { stop; limit } -> [
        "limit_price", Decimal_json.yojson_of_t limit;
        "stop_price", Decimal_json.yojson_of_t stop;
      ]
  in
  let payload : Yojson.Safe.t = `Assoc ([
    "symbol", `String (Symbol.to_string symbol);
    "side", `String (Side.to_string side);
    "quantity", Decimal_json.yojson_of_t quantity;
    "type", `String (Order.kind_to_string kind);
    "time_in_force", `String (Order.tif_to_string tif);
  ] @ price_fields)
  in
  post_json t path payload

let cancel_order t ~account_id ~order_id =
  delete t (Printf.sprintf "/v1/accounts/%s/orders/%s" account_id order_id)

(** Exposed for [Ws_bridge] so it can put the current JWT into the
    upgrade handshake's Authorization header. *)
let current_token t = Auth.current t.auth

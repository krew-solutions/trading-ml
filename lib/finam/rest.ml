(** Finam Trade REST client.
    Uses a pluggable [Transport.t] so the module is pure and testable;
    production wires in cohttp-eio, tests wire in an in-memory fake.

    Authentication is transparent: the client owns a [Auth.t] cache, and
    every request resolves a fresh JWT via [Auth.current] right before
    sending. The caller only provides the long-lived secret in [Config.t].
    On 401 we refresh once and retry — covers the race where the server
    invalidates the JWT slightly before our clock expects. *)

open Core

type t = {
  transport : Transport.t;
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

let ensure_ok (resp : Transport.response) =
  if resp.status >= 200 && resp.status < 300 then resp.body
  else failwith (Printf.sprintf "Finam REST %d: %s" resp.status resp.body)

(** Send a request with the current JWT. If the server rejects the JWT
    (401), refresh it once and retry — the cache's [exp] estimate may
    have been off, or the server rotated signing keys. *)
let send_with_auth_retry (t : t) (build_req : string -> Transport.request)
  : Transport.response =
  let token = Auth.current t.auth in
  let resp = t.transport (build_req token) in
  if resp.status = 401 then begin
    t.auth.state <- None;   (* force refresh *)
    let token' = Auth.current t.auth in
    t.transport (build_req token')
  end else resp

let req_with_token ~meth ~url ~body token : Transport.request = {
  meth;
  url;
  headers = [
    "Authorization", "Bearer " ^ token;
    "Accept", "application/json";
    "Content-Type", "application/json";
  ];
  body;
}

let _ = auth_headers

let get_json t path query : Yojson.Safe.t =
  let u = url t.cfg path query in
  let resp =
    send_with_auth_retry t
      (req_with_token ~meth:`GET ~url:u ~body:None)
  in
  Yojson.Safe.from_string (ensure_ok resp)

let post_json t path (payload : Yojson.Safe.t) : Yojson.Safe.t =
  let u = url t.cfg path [] in
  let resp =
    send_with_auth_retry t
      (req_with_token ~meth:`POST ~url:u
         ~body:(Some (Yojson.Safe.to_string payload)))
  in
  Yojson.Safe.from_string (ensure_ok resp)

let delete t path =
  let u = url t.cfg path [] in
  let resp =
    send_with_auth_retry t
      (req_with_token ~meth:`DELETE ~url:u ~body:None)
  in
  ignore (ensure_ok resp)

(** GET /v1/instruments/{symbol}/bars?timeframe=... *)
let bars
    ?from_ts ?to_ts
    (t : t) ~symbol ~timeframe : Candle.t list =
  let path =
    Printf.sprintf "/v1/instruments/%s/bars" (Symbol.to_string symbol)
  in
  let q = ["timeframe", Timeframe.to_finam timeframe] in
  let q = match from_ts with
    | Some v -> q @ ["interval.start_time", Int64.to_string v]
    | None -> q
  in
  let q = match to_ts with
    | Some v -> q @ ["interval.end_time", Int64.to_string v]
    | None -> q
  in
  Dto.candles_of_json (get_json t path q)

let account t ~account_id =
  get_json t (Printf.sprintf "/v1/accounts/%s" account_id) []

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

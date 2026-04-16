(** BCS REST client.
    Auth (Keycloak refresh_token → access_token) is handled by [Auth];
    consumers call business methods and the cached JWT is slipped into
    [Authorization: Bearer …] transparently. *)

open Core

type t = {
  transport : Http_transport.t;
  cfg : Config.t;
  auth : Auth.t;
}

let make ~transport ~cfg =
  let auth = Auth.make ~transport ~cfg in
  { transport; cfg; auth }

let req_with_token ~meth ~url ~body ~token : Http_transport.request = {
  meth;
  url;
  headers = [
    "Authorization", "Bearer " ^ token;
    "Accept", "application/json";
  ];
  body;
}

(** Send a request carrying the current access_token; on 401
    invalidate and retry exactly once (shared retry logic with
    [Finam.Rest]). *)
let send_with_auth_retry (t : t) ~meth ~url ~body =
  Http_transport.with_auth_retry t.transport
    ~get_token:(fun () -> Auth.current t.auth)
    ~invalidate:(fun () -> Auth.invalidate t.auth)
    ~build_request:(fun ~token ->
      req_with_token ~meth ~url ~body ~token)

let get_json t path query : Yojson.Safe.t =
  let base = t.cfg.Config.rest_base in
  let url = Uri.with_path base (Uri.path base ^ path) in
  let url = Uri.with_query' url query in
  let resp = send_with_auth_retry t ~meth:`GET ~url ~body:None in
  if resp.status < 200 || resp.status >= 300 then
    failwith (Printf.sprintf "BCS REST %d on %s: %s"
                resp.status (Uri.to_string url) resp.body);
  Yojson.Safe.from_string resp.body

(** RFC 3339 / ISO 8601 UTC with millisecond precision. BCS emits
    millis on responses; send the same shape for consistency. *)
let iso8601_of_ts (ts : int64) : string =
  let tm = Unix.gmtime (Int64.to_float ts) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.000Z"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** BCS timeframe enum, confirmed from the docs' swagger dropdown:
    `M1 M5 M15 M30 H1 H4 D W MN`. Note the daily/weekly/monthly codes
    drop the `1` suffix our internal enum carries. *)
let timeframe_wire : Timeframe.t -> string = function
  | M1 -> "M1" | M5 -> "M5" | M15 -> "M15" | M30 -> "M30"
  | H1 -> "H1" | H4 -> "H4"
  | D1 -> "D" | W1 -> "W" | MN1 -> "MN"

(** BCS identifies instruments by (classCode, ticker). The UI supplies
    a composite [TICKER@CLASS] string (symmetric to Finam's TICKER@MIC);
    bare tickers inherit [Config.default_class_code]. *)
let split_symbol cfg (symbol : Symbol.t) : string * string =
  let s = Symbol.to_string symbol in
  match String.index_opt s '@' with
  | Some i ->
    String.sub s 0 i,
    String.sub s (i + 1) (String.length s - i - 1)
  | None -> s, cfg.Config.default_class_code

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
let bars
    ?from_ts ?to_ts ?(n = 500)
    (t : t) ~symbol ~timeframe : Candle.t list =
  let ticker, class_code = split_symbol t.cfg symbol in
  let n = min n max_bars_per_request in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let tf_secs = Int64.of_int (Timeframe.to_seconds timeframe) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts = Option.value from_ts
    ~default:(Int64.sub end_ts (Int64.mul (Int64.of_int n) tf_secs)) in
  let query = [
    "classCode", class_code;
    "ticker",    ticker;
    "startDate", iso8601_of_ts start_ts;
    "endDate",   iso8601_of_ts end_ts;
    "timeFrame", timeframe_wire timeframe;
  ] in
  let j = get_json t
    "/trade-api-market-data-connector/api/v1/candles-chart" query in
  let items = match Yojson.Safe.Util.member "bars" j with
    | `List l -> l | _ -> []
  in
  List.map Candle_json.of_yojson_flex items
  |> List.sort (fun (a : Candle.t) b -> Int64.compare a.ts b.ts)

(** BCS doesn't expose a generic exchanges/venues endpoint that we've
    confirmed yet; return the standard MOEX boards as a static list.
    Users who need others can point [Config.default_class_code] at the
    right code directly. *)
let exchanges _t : Yojson.Safe.t =
  `Assoc [ "exchanges", `List [
    `Assoc [ "mic", `String "TQBR";  "name", `String "MOEX — T+ stocks" ];
    `Assoc [ "mic", `String "TQBS";  "name", `String "MOEX — T+ ETF" ];
    `Assoc [ "mic", `String "TQTF";  "name", `String "MOEX — T+ FinEx" ];
    `Assoc [ "mic", `String "TQOB";  "name", `String "MOEX — T+ bonds" ];
    `Assoc [ "mic", `String "SPBXM"; "name", `String "SPB — foreign" ];
  ]]

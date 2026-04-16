(** Minimal HTTP server using cohttp-eio. Exposes:
      GET  /api/indicators
      GET  /api/strategies
      GET  /api/candles?symbol=...&n=N&timeframe=...
      GET  /api/stream?symbol=...&timeframe=...        (Server-Sent Events)
      POST /api/backtest                JSON body

    CORS is opened for localhost Angular dev server. *)

open Core

let json_response ?(status = `OK) (j : Yojson.Safe.t) =
  let body = Cohttp_eio.Body.of_string (Yojson.Safe.to_string j) in
  let headers = Cohttp.Header.of_list [
    "Content-Type", "application/json";
    "Access-Control-Allow-Origin", "*";
    "Access-Control-Allow-Methods", "GET, POST, OPTIONS";
    "Access-Control-Allow-Headers", "Content-Type";
  ] in
  Cohttp_eio.Server.respond ~status ~headers ~body ()

let string_response ?(status = `OK) s =
  let body = Cohttp_eio.Body.of_string s in
  let headers = Cohttp.Header.of_list [
    "Content-Type", "text/plain";
    "Access-Control-Allow-Origin", "*";
  ] in
  Cohttp_eio.Server.respond ~status ~headers ~body ()

let get_query uri k =
  match Uri.get_query_param uri k with
  | Some v -> v | None -> ""

let get_query_int uri k d =
  match Uri.get_query_param uri k with
  | Some s -> (try int_of_string s with _ -> d)
  | None -> d

let parse_timeframe s =
  try Timeframe.of_string s with _ -> Timeframe.H1

(** Source for candle data. [Live] is broker-agnostic — wraps any
    [Broker.client] (Finam, BCS, …). *)
type source =
  | Synthetic
  | Live of Broker.client

let synthetic_candles ~n ~timeframe =
  Synthetic.generate ~n ~start_ts:1_704_067_200L
    ~tf_seconds:(Timeframe.to_seconds timeframe) ~start_price:100.0

(** Deterministic wobble on the trailing bar so the synthetic stream
    produces visible updates at every poll tick. The bar identity (ts)
    doesn't change, only its close drifts and high/low extend. *)
let wobble_last ~rng candles =
  match List.rev candles with
  | [] -> []
  | last :: rest_rev ->
    let f = Decimal.to_float last.Candle.close in
    let drift = (rng () *. 2.0 -. 1.0) *. 0.3 in
    let close = Float.max 1.0 (f +. drift) in
    let high = Float.max (Decimal.to_float last.high) close in
    let low = Float.min (Decimal.to_float last.low) close in
    let updated = Candle.make
      ~ts:last.ts
      ~open_:last.open_
      ~high:(Decimal.of_float high)
      ~low:(Decimal.of_float low)
      ~close:(Decimal.of_float close)
      ~volume:(Decimal.add last.volume (Decimal.of_int 100))
    in
    List.rev (updated :: rest_rev)

(** Global RNG per-process for synthetic wobble. *)
let wobble_rng =
  let state = Random.State.make_self_init () in
  fun () -> Random.State.float state 1.0

let live_or_synthetic source ~symbol ~n ~timeframe =
  match source with
  | Synthetic -> synthetic_candles ~n ~timeframe
  | Live client ->
    try Broker.bars client ~n ~symbol ~timeframe
    with e ->
      Log.warn "%s bars(%s) failed: %s — falling back to synthetic"
        (Broker.name client) (Symbol.to_string symbol) (Printexc.to_string e);
      synthetic_candles ~n ~timeframe

(** Source for the streaming endpoint — in synthetic mode we wobble the
    last bar so the chart visibly ticks; in live mode we just re-fetch. *)
let stream_fetch source ~symbol ~n ~timeframe =
  match source with
  | Synthetic ->
    synthetic_candles ~n ~timeframe
    |> wobble_last ~rng:wobble_rng
  | Live _ -> live_or_synthetic source ~symbol ~n ~timeframe

let strategy_params_of_json j =
  match j with
  | `Null -> []
  | `Assoc fields ->
    List.filter_map (fun (k, v) ->
      match v with
      | `Int n -> Some (k, Strategies.Registry.Int n)
      | `Float f -> Some (k, Strategies.Registry.Float f)
      | `Bool b -> Some (k, Strategies.Registry.Bool b)
      | _ -> None) fields
  | _ -> []

let run_backtest source body_str =
  let j = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let symbol = Symbol.of_string (member "symbol" j |> to_string) in
  let strat_name = member "strategy" j |> to_string in
  let params = strategy_params_of_json (member "params" j) in
  let n = match member "n" j with `Int n -> n | _ -> 500 in
  let timeframe = match member "timeframe" j with
    | `String s -> parse_timeframe s
    | _ -> Timeframe.H1
  in
  match Strategies.Registry.find strat_name with
  | None -> `Assoc [ "error", `String "unknown strategy" ]
  | Some spec ->
    let strat = spec.build params in
    let candles = live_or_synthetic source ~symbol ~n ~timeframe in
    let cfg = Engine.Backtest.default_config () in
    let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~symbol ~candles in
    Api.backtest_result_json r

(** Initial payload describing the current cached candles, sent to the
    client right after the HTTP headers so the UI can render without a
    separate /api/candles roundtrip. *)
let seed_chunk seed =
  let j : Yojson.Safe.t = `Assoc [
    "kind", `String "seed";
    "candles", `List (List.map Candle_json.yojson_of_t seed);
  ] in
  "data: " ^ Yojson.Safe.to_string j ^ "\n\n"

(** SSE handler returned in [`Expert] mode. Writes pre-formatted chunks
    directly to the buffered output with an explicit flush after each
    one — cohttp-eio's default [Response] path batches the body into a
    single response, which would never push live events. *)
let sse_expert (registry : Stream.t) ~symbol ~timeframe =
  let client, seed = Stream.subscribe registry ~symbol ~timeframe in
  Log.info "SSE open  %s/%s seed=%d bars"
    (Symbol.to_string symbol) (Timeframe.to_string timeframe)
    (List.length seed);
  let headers = Cohttp.Header.of_list [
    "Content-Type", "text/event-stream";
    "Cache-Control", "no-cache";
    "Connection", "close";
    "X-Accel-Buffering", "no";
    "Access-Control-Allow-Origin", "*";
  ] in
  let response =
    Cohttp.Response.make ~status:`OK ~headers
      ~encoding:(Cohttp.Transfer.Unknown) ()
  in
  response, fun _ic (oc : Eio.Buf_write.t) ->
    (* cohttp auto-sets Transfer-Encoding: chunked when the response has no
       Content-Length, so we must frame every event in chunked encoding:
         <hex-size>\r\n<data>\r\n   then a terminal 0\r\n\r\n on close. *)
    let push_chunk data =
      let size = String.length data in
      Eio.Buf_write.string oc (Printf.sprintf "%x\r\n" size);
      Eio.Buf_write.string oc data;
      Eio.Buf_write.string oc "\r\n";
      Eio.Buf_write.flush oc
    in
    (try
       push_chunk (seed_chunk seed);
       while true do
         let chunk = Eio.Stream.take client.queue in
         push_chunk chunk
       done
     with _ -> ());
    (try
       Eio.Buf_write.string oc "0\r\n\r\n";
       Eio.Buf_write.flush oc
     with _ -> ());
    Stream.unsubscribe registry ~symbol ~timeframe client;
    Log.info "SSE close %s/%s"
      (Symbol.to_string symbol) (Timeframe.to_string timeframe)

(** Pure routing: given method+path, return (status, action). Kept
    separate from request logging so [handler] can log uniformly. *)
let route source registry request body : int * Cohttp_eio.Server.response_action =
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  let ok r = 200, `Response r in
  try
    match meth, path with
    | `OPTIONS, _ -> 204, `Response (string_response "")
    | `GET, "/api/indicators" ->
      ok (json_response (Api.indicators_catalog ()))
    | `GET, "/api/strategies" ->
      ok (json_response (Api.strategies_catalog ()))
    | `GET, "/api/exchanges" ->
      let exchanges : Broker.exchange list = match source with
        | Synthetic ->
          (* Static list mirrors the UI's built-in fallback. *)
          [ { mic = "MISX"; name = "MOEX" };
            { mic = "XSPB"; name = "SPB Exchange" } ]
        | Live client ->
          (try Broker.exchanges client
           with e ->
             Log.warn "%s exchanges failed: %s"
               (Broker.name client) (Printexc.to_string e);
             [])
      in
      let j : Yojson.Safe.t = `Assoc [
        "exchanges", `List (List.map (fun (e : Broker.exchange) ->
          `Assoc [ "mic", `String e.mic; "name", `String e.name ]) exchanges)
      ] in
      ok (json_response j)
    | `GET, "/api/candles" ->
      let symbol = Symbol.of_string (get_query uri "symbol") in
      let n = get_query_int uri "n" 500 in
      let timeframe = parse_timeframe (get_query uri "timeframe") in
      ok (json_response
        (Api.candles_json (live_or_synthetic source ~symbol ~n ~timeframe)))
    | `GET, "/api/stream" ->
      let symbol = Symbol.of_string (get_query uri "symbol") in
      let timeframe = parse_timeframe (get_query uri "timeframe") in
      200, `Expert (sse_expert registry ~symbol ~timeframe)
    | `POST, "/api/backtest" ->
      let body = Eio.Flow.read_all body in
      ok (json_response (run_backtest source body))
    | `GET, "/" | `GET, "/health" ->
      let mode = match source with
        | Synthetic -> "synthetic"
        | Live c -> "live:" ^ Broker.name c
      in
      ok (string_response ("ok (" ^ mode ^ ")"))
    | _ -> 404, `Response (string_response ~status:`Not_found "not found")
  with e ->
    500, `Response (json_response ~status:`Internal_server_error
      (`Assoc ["error", `String (Printexc.to_string e)]))

let handler source registry _conn request body =
  let t0 = Unix.gettimeofday () in
  let uri = Cohttp.Request.uri request in
  let meth_str =
    Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let line =
    let q = Uri.query uri in
    if q = [] then Uri.path uri
    else Uri.path uri ^ "?" ^ Uri.encoded_of_query q
  in
  let status, action = route source registry request body in
  let dt_ms = (Unix.gettimeofday () -. t0) *. 1000. in
  (match action with
   | `Expert _ ->
     (* SSE is logged separately at open/close; skip here. *)
     ()
   | `Response _ ->
     Log.info "%s %s → %d (%.1fms)" meth_str line status dt_ms);
  action

let run ~env ~port ~source =
  Eio.Switch.run @@ fun sw ->
  let fetch ~symbol ~n ~timeframe =
    stream_fetch source ~symbol ~n ~timeframe in
  let registry = Stream.create ~env ~sw ~fetch in
  let socket =
    Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw
      (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server =
    Cohttp_eio.Server.make_response_action
      ~callback:(handler source registry) ()
  in
  Cohttp_eio.Server.run socket server ~on_error:raise

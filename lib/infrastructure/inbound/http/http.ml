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

(** Fetch bars from whatever broker the server was started with.
    Errors propagate as exceptions — both call sites handle them:

    - HTTP [/api/candles] wraps routing in a top-level try/with that
      turns the exception into a 500 response, so the UI sees a real
      error rather than a misleading empty chart.
    - The [Stream] polling fiber swallows exceptions and keeps the
      previous cache intact, so a transient upstream failure doesn't
      wipe the subscribers' view or gate the WS fan-out (which
      depends on the cache being non-empty).

    Previously we'd silently fall back to a synthetic generator or
    return []. Both masked real errors. Callers that want
    deterministic mock data run the server with [--broker synthetic]
    — a {!Synthetic.Synthetic_broker} adapter on the same path. *)
let fetch_candles client ~instrument ~n ~timeframe =
  Broker.bars client ~n ~instrument ~timeframe

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

let run_backtest client body_str =
  let j = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let instrument = Instrument.of_qualified (member "symbol" j |> to_string) in
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
    let candles = fetch_candles client ~instrument ~n ~timeframe in
    let cfg = Engine.Backtest.default_config () in
    let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~instrument ~candles in
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
let sse_expert (registry : Stream.t) ~instrument ~timeframe =
  let client, seed = Stream.subscribe registry ~instrument ~timeframe in
  Log.info "SSE open  %s/%s seed=%d bars"
    (Instrument.to_qualified instrument) (Timeframe.to_string timeframe)
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
    Stream.unsubscribe registry ~instrument ~timeframe client;
    Log.info "SSE close %s/%s"
      (Instrument.to_qualified instrument) (Timeframe.to_string timeframe)

(** Pure routing: given method+path, return (status, action). Kept
    separate from request logging so [handler] can log uniformly. *)
let route client registry request body : int * Cohttp_eio.Server.response_action =
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
      let venues =
        try Broker.venues client
        with e ->
          Log.warn "%s venues failed: %s"
            (Broker.name client) (Printexc.to_string e);
          []
      in
      let j : Yojson.Safe.t = `Assoc [
        "exchanges", `List (List.map (fun m -> `String (Mic.to_string m)) venues)
      ] in
      ok (json_response j)
    | `GET, "/api/candles" ->
      let instrument = Instrument.of_qualified (get_query uri "symbol") in
      let n = get_query_int uri "n" 500 in
      let timeframe = parse_timeframe (get_query uri "timeframe") in
      ok (json_response
        (Api.candles_json (fetch_candles client ~instrument ~n ~timeframe)))
    | `GET, "/api/stream" ->
      let instrument = Instrument.of_qualified (get_query uri "symbol") in
      let timeframe = parse_timeframe (get_query uri "timeframe") in
      200, `Expert (sse_expert registry ~instrument ~timeframe)
    | `POST, "/api/backtest" ->
      let body = Eio.Flow.read_all body in
      ok (json_response (run_backtest client body))
    | `GET, "/" | `GET, "/health" ->
      ok (string_response ("ok (" ^ Broker.name client ^ ")"))
    | _ -> 404, `Response (string_response ~status:`Not_found "not found")
  with e ->
    500, `Response (json_response ~status:`Internal_server_error
      (`Assoc ["error", `String (Printexc.to_string e)]))

let handler client registry _conn request body =
  let t0 = Unix.gettimeofday () in
  let uri = Cohttp.Request.uri request in
  let meth_str =
    Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let line =
    let q = Uri.query uri in
    if q = [] then Uri.path uri
    else Uri.path uri ^ "?" ^ Uri.encoded_of_query q
  in
  let status, action = route client registry request body in
  let dt_ms = (Unix.gettimeofday () -. t0) *. 1000. in
  (match action with
   | `Expert _ ->
     (* SSE is logged separately at open/close; skip here. *)
     ()
   | `Response _ ->
     Log.info "%s %s → %d (%.1fms)" meth_str line status dt_ms);
  action

(** Live-data wiring extension point. The caller (e.g. {!Bin.Main})
    decides whether to attach a WS upstream: it gets the [sw] for
    spawning fibers, returns lifecycle hooks for [Stream.create], and
    receives the freshly-built [Stream.t] via [bind] to wire the
    inbound event flow back into [push_from_upstream]. *)
type live_setup = {
  on_first : Stream.lifecycle_hook;
  on_last  : Stream.lifecycle_hook;
  bind     : Stream.t -> unit;
}

let no_live_setup : live_setup = {
  on_first = (fun ~instrument:_ ~timeframe:_ -> ());
  on_last  = (fun ~instrument:_ ~timeframe:_ -> ());
  bind     = (fun _ -> ());
}

let run ?(setup = fun ~sw:_ -> no_live_setup) ~env ~port ~client () =
  Eio.Switch.run @@ fun sw ->
  let s = setup ~sw in
  let fetch ~instrument ~n ~timeframe =
    fetch_candles client ~instrument ~n ~timeframe in
  let registry =
    Stream.create
      ~on_first_subscriber:s.on_first
      ~on_last_unsubscriber:s.on_last
      ~env ~sw ~fetch () in
  s.bind registry;
  let socket =
    Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw
      (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server =
    Cohttp_eio.Server.make_response_action
      ~callback:(handler client registry) ()
  in
  Cohttp_eio.Server.run socket server ~on_error:raise

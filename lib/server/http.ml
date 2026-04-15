(** Minimal HTTP server using cohttp-eio. Exposes:
      GET  /api/indicators              — catalog
      GET  /api/strategies              — catalog
      GET  /api/candles?symbol=...&n=N  — demo candles
      POST /api/backtest                — JSON body {symbol, strategy, params, n}
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

(* Demo candles store: regenerate per request on a deterministic seed. *)
let demo_candles ~symbol ~n ~timeframe =
  ignore symbol;
  Synthetic.generate ~n ~start_ts:1_704_067_200L
    ~tf_seconds:(Timeframe.to_seconds timeframe) ~start_price:100.0

let parse_timeframe s =
  try Timeframe.of_string s with _ -> Timeframe.H1

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

let run_backtest body_str =
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
    let candles = demo_candles ~symbol ~n ~timeframe in
    let cfg = Engine.Backtest.default_config () in
    let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~symbol ~candles in
    Api.backtest_result_json r

let handler _socket request body =
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  try
    match meth, path with
    | `OPTIONS, _ -> string_response ""
    | `GET, "/api/indicators" -> json_response (Api.indicators_catalog ())
    | `GET, "/api/strategies" -> json_response (Api.strategies_catalog ())
    | `GET, "/api/candles" ->
      let symbol = Symbol.of_string (get_query uri "symbol") in
      let n = get_query_int uri "n" 500 in
      let timeframe = parse_timeframe (get_query uri "timeframe") in
      json_response
        (Api.candles_json (demo_candles ~symbol ~n ~timeframe))
    | `POST, "/api/backtest" ->
      let body = Eio.Flow.read_all body in
      json_response (run_backtest body)
    | `GET, "/" | `GET, "/health" -> string_response "ok"
    | _ -> string_response ~status:`Not_found "not found"
  with e ->
    json_response ~status:`Internal_server_error
      (`Assoc ["error", `String (Printexc.to_string e)])

let run ~env ~port =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw
      (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Cohttp_eio.Server.run socket server ~on_error:raise

(** Minimal HTTP server using cohttp-eio. Exposes:
      GET  /api/indicators
      GET  /api/strategies
      GET  /api/candles?symbol=...&n=N&timeframe=...
      GET  /api/stream[?bars=SYMBOL:TF,SYMBOL:TF,...]  (Server-Sent Events)
      POST /api/backtest                JSON body

    CORS is opened for localhost Angular dev server. *)

open Core

let json_response ?(status = `OK) (j : Yojson.Safe.t) =
  let body = Cohttp_eio.Body.of_string (Yojson.Safe.to_string j) in
  let headers =
    Cohttp.Header.of_list
      [
        ("Content-Type", "application/json");
        ("Access-Control-Allow-Origin", "*");
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        ("Access-Control-Allow-Headers", "Content-Type");
      ]
  in
  Cohttp_eio.Server.respond ~status ~headers ~body ()

let string_response ?(status = `OK) s =
  let body = Cohttp_eio.Body.of_string s in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "text/plain"); ("Access-Control-Allow-Origin", "*") ]
  in
  Cohttp_eio.Server.respond ~status ~headers ~body ()

let get_query uri k =
  match Uri.get_query_param uri k with
  | Some v -> v
  | None -> ""

let get_query_int uri k d =
  match Uri.get_query_param uri k with
  | Some s -> ( try int_of_string s with _ -> d)
  | None -> d

let parse_timeframe s = try Timeframe.of_string s with _ -> Timeframe.H1

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
let fetch_candles broker ~instrument ~n ~timeframe =
  Broker.bars broker ~n ~instrument ~timeframe

let strategy_params_of_json j =
  match j with
  | `Null -> []
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `Int n -> Some (k, Strategies.Registry.Int n)
          | `Float f -> Some (k, Strategies.Registry.Float f)
          | `Bool b -> Some (k, Strategies.Registry.Bool b)
          | `String s -> Some (k, Strategies.Registry.String s)
          | _ -> None)
        fields
  | _ -> []

let run_backtest broker body_str =
  let j = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let instrument = Instrument.of_qualified (member "symbol" j |> to_string) in
  let strat_name = member "strategy" j |> to_string in
  let params = strategy_params_of_json (member "params" j) in
  let n =
    match member "n" j with
    | `Int n -> n
    | _ -> 500
  in
  let timeframe =
    match member "timeframe" j with
    | `String s -> parse_timeframe s
    | _ -> Timeframe.H1
  in
  match Strategies.Registry.find strat_name with
  | None -> `Assoc [ ("error", `String "unknown strategy") ]
  | Some spec ->
      let strat = spec.build params in
      let candles = fetch_candles broker ~instrument ~n ~timeframe in
      let cfg = Engine.Backtest.default_config () in
      let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~instrument ~candles in
      Api.backtest_result_json r

(** Per-bar-feed seed payload. Rides the [bar] SSE channel with
    [kind: "seed"], symbol+timeframe metadata identifies which feed,
    so the browser dispatches inside its single
    [addEventListener("bar", ...)] handler. *)
let seed_chunk ~instrument ~timeframe seed =
  let j : Yojson.Safe.t =
    `Assoc
      [
        ("kind", `String "seed");
        ("symbol", `String (Instrument.to_qualified instrument));
        ("timeframe", `String (Timeframe.to_string timeframe));
        ("candles", `List (List.map Api.candle_json seed));
      ]
  in
  "event: bar\ndata: " ^ Yojson.Safe.to_string j ^ "\n\n"

(** Parse [?bars=SYMBOL@MIC[/BOARD]:TF,SYMBOL@MIC:TF,...] into a list
    of bar feed keys. Empty / malformed entries silently skipped. *)
let parse_bars_param s =
  if s = "" then []
  else
    String.split_on_char ',' s
    |> List.filter_map (fun raw ->
        let raw = String.trim raw in
        if raw = "" then None
        else
          match String.rindex_opt raw ':' with
          | None -> None
          | Some i -> (
              let sym = String.sub raw 0 i in
              let tf = String.sub raw (i + 1) (String.length raw - i - 1) in
              try Some (Instrument.of_qualified sym, Timeframe.of_string tf)
              with _ -> None))

(** SSE handler returned in [`Expert] mode. Writes pre-formatted chunks
    directly to the buffered output with an explicit flush after each
    one — cohttp-eio's default [Response] path batches the body into a
    single response, which would never push live events. *)
let sse_expert (registry : Stream.t) ~bar_keys =
  let subscriber = Stream.connect registry in
  let seeds =
    List.map
      (fun (instrument, timeframe) ->
        let candles = Stream.subscribe_bar registry subscriber ~instrument ~timeframe in
        (instrument, timeframe, candles))
      bar_keys
  in
  Log.info "SSE open id=%d bars=[%s]" subscriber.id
    (String.concat ","
       (List.map
          (fun (i, tf, cs) ->
            Printf.sprintf "%s:%s(%d)" (Instrument.to_qualified i)
              (Timeframe.to_string tf) (List.length cs))
          seeds));
  let headers =
    Cohttp.Header.of_list
      [
        ("Content-Type", "text/event-stream");
        ("Cache-Control", "no-cache");
        ("Connection", "close");
        ("X-Accel-Buffering", "no");
        ("Access-Control-Allow-Origin", "*");
      ]
  in
  let response =
    Cohttp.Response.make ~status:`OK ~headers ~encoding:Cohttp.Transfer.Unknown ()
  in
  ( response,
    fun _ic (oc : Eio.Buf_write.t) ->
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
         List.iter
           (fun (instrument, timeframe, candles) ->
             push_chunk (seed_chunk ~instrument ~timeframe candles))
           seeds;
         while true do
           let chunk = Eio.Stream.take subscriber.queue in
           push_chunk chunk
         done
       with _ -> ());
      (try
         Eio.Buf_write.string oc "0\r\n\r\n";
         Eio.Buf_write.flush oc
       with _ -> ());
      Stream.disconnect registry subscriber;
      Log.info "SSE close id=%d" subscriber.id )

type buses = {
  reserve : Account_commands.Reserve_command.t Bus.Command_bus.t;
  submit_order : Broker_commands.Submit_order_command.t Bus.Command_bus.t;
}
(** Composition-root bundle threaded into the HTTP layer. Both
    Command_buses are async fire-and-forget; outcomes for the
    request flow back as integration events on the corresponding
    Event_buses. The HTTP response is a 202 with the cross-BC
    saga key the UI uses to filter SSE updates. *)

(** Project a parsed [place_order_request] into a
    {!Account_commands.Reserve_command.t}. The [price] is the
    cash-impact reference for reservation: prefer the kind's own
    target price (limit / stop) when present; for market orders
    fall back to the latest broker mark fetched on demand. *)
let to_reserve_command broker (req : Api.place_order_request) :
    Account_commands.Reserve_command.t =
  let price =
    match req.kind with
    | Limit p | Stop p -> Decimal.to_float p
    | Stop_limit { limit; _ } -> Decimal.to_float limit
    | Market -> (
        match
          Broker.bars broker ~n:1 ~instrument:req.instrument ~timeframe:Timeframe.H1
        with
        | last :: _ -> Decimal.to_float last.close
        | [] -> 0.0)
  in
  {
    side = Side.to_string req.side;
    symbol = Instrument.to_qualified req.instrument;
    quantity = Decimal.to_float req.quantity;
    price;
  }

(** Project a parsed [place_order_request] into a
    {!Broker_commands.Submit_order_command.t} once Account has
    surfaced the [reservation_id] (the cross-BC saga key). *)
let to_submit_order_command ~reservation_id (req : Api.place_order_request) :
    Broker_commands.Submit_order_command.t =
  {
    reservation_id;
    symbol = Instrument.to_qualified req.instrument;
    side = Side.to_string req.side;
    quantity = Decimal.to_float req.quantity;
    kind = Queries.Order_kind_view_model.of_domain req.kind;
    tif = Order.tif_to_string req.tif;
  }

(** Pure routing: given method+path, return (status, action). Kept
    separate from request logging so [handler] can log uniformly. *)
let route ~broker ~buses ~registry request body : int * Cohttp_eio.Server.response_action
    =
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  let ok r = (200, `Response r) in
  try
    match (meth, path) with
    | `OPTIONS, _ -> (204, `Response (string_response ""))
    | `GET, "/api/indicators" -> ok (json_response (Api.indicators_catalog ()))
    | `GET, "/api/strategies" -> ok (json_response (Api.strategies_catalog ()))
    | `GET, "/api/exchanges" ->
        let venues =
          try Broker.venues broker
          with e ->
            Log.warn "%s venues failed: %s" (Broker.name broker) (Printexc.to_string e);
            []
        in
        let j : Yojson.Safe.t =
          `Assoc
            [
              ("exchanges", `List (List.map (fun m -> `String (Mic.to_string m)) venues));
            ]
        in
        ok (json_response j)
    | `GET, "/api/candles" ->
        let instrument = Instrument.of_qualified (get_query uri "symbol") in
        let n = get_query_int uri "n" 500 in
        let timeframe = parse_timeframe (get_query uri "timeframe") in
        ok
          (json_response
             (Api.candles_json (fetch_candles broker ~instrument ~n ~timeframe)))
    | `GET, "/api/stream" ->
        let bar_keys = parse_bars_param (get_query uri "bars") in
        (200, `Expert (sse_expert registry ~bar_keys))
    | `POST, "/api/backtest" ->
        let body = Eio.Flow.read_all body in
        ok (json_response (run_backtest broker body))
    | `GET, "/api/orders" ->
        let orders = Broker.get_orders broker in
        ok (json_response (Api.orders_json orders))
    | `POST, "/api/orders" ->
        let body = Eio.Flow.read_all body in
        let req = Api.place_order_of_json (Yojson.Safe.from_string body) in
        Bus.Command_bus.send buses.reserve (to_reserve_command broker req);
        (* TODO: reservation_id is not synchronously knowable on the
           async bus — outcomes will arrive on integration-event
           channels, not back through [send]. The Submit dispatch
           and the HTTP response shape need a proper saga key
           (HTTP-generated correlation_id) and an SSE-driven
           UI flow. Placeholder 202 returned for now. *)
        ignore (to_submit_order_command, buses.submit_order);
        ( 202,
          `Response
            (json_response ~status:`Accepted (`Assoc [ ("status", `String "accepted") ]))
        )
    | `GET, path when String.length path > 12 && String.sub path 0 12 = "/api/orders/" ->
        let cid = String.sub path 12 (String.length path - 12) in
        let o = Broker.get_order broker ~client_order_id:cid in
        ok (json_response (Api.order_json o))
    | `DELETE, path when String.length path > 12 && String.sub path 0 12 = "/api/orders/"
      ->
        let cid = String.sub path 12 (String.length path - 12) in
        let o = Broker.cancel_order broker ~client_order_id:cid in
        ok (json_response (Api.order_json o))
    | `GET, "/" | `GET, "/health" ->
        ok (string_response ("ok (" ^ Broker.name broker ^ ")"))
    | _ -> (404, `Response (string_response ~status:`Not_found "not found"))
  with e ->
    ( 500,
      `Response
        (json_response ~status:`Internal_server_error
           (`Assoc [ ("error", `String (Printexc.to_string e)) ])) )

let handler ~broker ~buses ~registry _conn request body =
  let t0 = Unix.gettimeofday () in
  let uri = Cohttp.Request.uri request in
  let meth_str = Cohttp.Code.string_of_method (Cohttp.Request.meth request) in
  let line =
    let q = Uri.query uri in
    if q = [] then Uri.path uri else Uri.path uri ^ "?" ^ Uri.encoded_of_query q
  in
  let status, action = route ~broker ~buses ~registry request body in
  let dt_ms = (Unix.gettimeofday () -. t0) *. 1000. in
  (match action with
  | `Expert _ ->
      (* SSE is logged separately at open/close; skip here. *)
      ()
  | `Response _ -> Log.info "%s %s → %d (%.1fms)" meth_str line status dt_ms);
  action

type live_setup = {
  on_first : Stream.lifecycle_hook;
  on_last : Stream.lifecycle_hook;
  bind : Stream.t -> unit;
}
(** Live-data wiring extension point. The caller (e.g. {!Bin.Main})
    decides whether to attach a WS upstream: it gets the [sw] for
    spawning fibers, returns lifecycle hooks for [Stream.create], and
    receives the freshly-built [Stream.t] via [bind] to wire the
    inbound event flow back into [push_from_upstream]. *)

let no_live_setup : live_setup =
  {
    on_first = (fun ~instrument:_ ~timeframe:_ -> ());
    on_last = (fun ~instrument:_ ~timeframe:_ -> ());
    bind = (fun _ -> ());
  }

let run
    ?(setup = fun ~sw:_ -> no_live_setup)
    ~sw
    ~env
    ~port
    ~broker
    ~buses
    ~(register_publisher : Stream.t -> unit)
    () =
  let s = setup ~sw in
  let fetch ~instrument ~n ~timeframe = fetch_candles broker ~instrument ~n ~timeframe in
  let registry =
    Stream.create ~on_first_subscriber:s.on_first ~on_last_unsubscriber:s.on_last ~env ~sw
      ~fetch ()
  in
  s.bind registry;
  register_publisher registry;
  let socket =
    Eio.Net.listen ~reuse_addr:true ~backlog:16 ~sw (Eio.Stdenv.net env)
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server =
    Cohttp_eio.Server.make_response_action ~callback:(handler ~broker ~buses ~registry) ()
  in
  Cohttp_eio.Server.run socket server ~on_error:raise

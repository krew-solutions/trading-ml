(** CLI entry point.
    Subcommands:
      trading serve [--port 8080] [--live]
                    [--secret SECRET] [--account ACCOUNT_ID]
        start HTTP API server.
        --live  switches from synthetic data to real Finam REST.
                Auth uses Finam's two-step flow: you pass the long-lived
                *secret* (from the Finam portal); the client exchanges
                it for a short-lived JWT and refreshes before expiry.
                secret / account_id may also come from FINAM_SECRET /
                FINAM_ACCOUNT_ID environment variables.

      trading list
        show registered indicators and strategies.

      trading backtest <strategy> [--n N] [--symbol SBER]
        run a backtest on synthetic data and print summary. *)

open Core
open Broker_boot

let usage () =
  prerr_endline
    {|trading <command> [options]

  serve [--port 8080] [--broker synthetic|finam|bcs] [--paper]
        [--strategy NAME] [--engine-symbol SBER@MISX]
        [--secret SECRET] [--account ACCOUNT_ID]
        [--client-id CLIENT_ID]
        [--log-level debug|info|warning|error]
      start HTTP API server (bound to localhost).
      --broker selects the data source (default: synthetic).
      Credentials (same convention for both live brokers):
        --secret VALUE  or  <BROKER>_SECRET env var (FINAM_SECRET, BCS_SECRET)
        --account VALUE or  <BROKER>_ACCOUNT_ID env var
      BCS-only:
        --client-id VALUE or BCS_CLIENT_ID env var. Must match the
        Keycloak client under which your refresh-token was issued —
        "trade-api-write" for a trading account (default),
        "trade-api-read" for a data-only account. Sending a token
        with the wrong client yields a 400 "invalid_grant / Token
        client and authorized client don't match".
      For BCS the "secret" is your Keycloak refresh-token from the
      portal. After the first run it is persisted (with chmod 0600)
      to $XDG_STATE_HOME/trading/bcs-refresh-token; rotations land
      there automatically, so subsequent runs don't need --secret or
      BCS_SECRET. Pass --secret again only to force-overwrite a
      stale token. Synthetic ignores credentials and serves a
      deterministic random-walk through the same Broker.S port.
      --paper wraps the selected broker in an in-memory order
      simulator: bars still come from the real source (or synthetic),
      but every order is intercepted and filled against the live
      candle stream. Use for strategy smoke-testing before routing to
      a real broker.
      --strategy NAME attaches a live engine that feeds every upstream
      bar into the named strategy (see `trading list`) and submits
      market orders via the broker. Combine with --paper for a safe
      dry-run. Engine symbol defaults to SBER@MISX.

  list
      show registered indicators and strategies

  backtest <strategy> [--n N] [--symbol SBER@MISX]
                      [--param KEY=VALUE ...]
      run a backtest on synthetic data and print summary.
      --param can be repeated; keys and types come from the
      strategy's registry entry (see `trading list`). Example:
        trading backtest GBT --param model_path=/tmp/sber.txt \
                             --param enter_threshold=0.6

Offline data / model tooling ships as separate binaries to keep
this runtime CLI focused on live operations:

  dune exec -- bin/export_training_data.exe -- --help
      offline dataset builder for the GBT training pipeline

  orders <list|get|place|cancel> [--host http://localhost:8080]
      talk to a running `serve` instance via its /api/orders surface.
      Use this to smoke-test paper mode or poke live broker orders
      without touching the UI. Run `orders` with no subcommand for
      per-action flags.
|};
  exit 2

let cmd_list () =
  print_endline "Indicators:";
  List.iter
    (fun s -> Printf.printf "  - %s\n" s.Indicators.Registry.name)
    Indicators.Registry.specs;
  print_endline "Strategies:";
  List.iter
    (fun s -> Printf.printf "  - %s\n" s.Strategies.Registry.name)
    Strategies.Registry.specs

(** Collect every value that follows a given flag; useful for repeated
    CLI args like [--param KEY=VALUE --param OTHER=VAL]. *)
let arg_values name args =
  let rec go acc = function
    | k :: v :: rest when k = name -> go (v :: acc) rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] args

(** Parse one [KEY=VALUE] string against the spec's declared
    parameter types. Returns [(key, coerced_param)] or raises
    [Invalid_argument] with a pointed message.

    We look up the key's declared type in [spec.params] (the entry
    default tells us whether it's Int / Float / Bool / String), then
    coerce the value accordingly. Unknown keys are rejected rather
    than silently dropped — a typo in a CLI invocation that looks
    like it worked but had no effect is a worse failure mode than
    an error. *)
let parse_strategy_param (spec : Strategies.Registry.spec) (kv : string) :
    string * Strategies.Registry.param =
  match String.index_opt kv '=' with
  | None -> invalid_arg (Printf.sprintf "--param expects KEY=VALUE, got %S" kv)
  | Some i -> (
      let k = String.sub kv 0 i in
      let v = String.sub kv (i + 1) (String.length kv - i - 1) in
      match List.assoc_opt k spec.params with
      | None ->
          invalid_arg
            (Printf.sprintf "unknown --param key %S for strategy %S (expected one of: %s)"
               k spec.name
               (String.concat ", " (List.map fst spec.params)))
      | Some (Strategies.Registry.Int _) -> (k, Strategies.Registry.Int (int_of_string v))
      | Some (Strategies.Registry.Float _) ->
          (k, Strategies.Registry.Float (float_of_string v))
      | Some (Strategies.Registry.Bool _) ->
          (k, Strategies.Registry.Bool (bool_of_string v))
      | Some (Strategies.Registry.String _) -> (k, Strategies.Registry.String v))

let strategy_params_from_args spec args : (string * Strategies.Registry.param) list =
  arg_values "--param" args |> List.map (parse_strategy_param spec)

let cmd_backtest args =
  let strat_name =
    match args with
    | n :: _ -> n
    | [] -> usage ()
  in
  let n =
    let rec find = function
      | "--n" :: v :: _ -> int_of_string v
      | _ :: rest -> find rest
      | [] -> 500
    in
    find args
  in
  let instrument =
    let rec find = function
      | "--symbol" :: v :: _ -> Instrument.of_qualified v
      | _ :: rest -> find rest
      | [] -> Instrument.of_qualified "SBER@MISX"
    in
    find args
  in
  match Strategies.Registry.find strat_name with
  | None ->
      Printf.eprintf "unknown strategy %s\n" strat_name;
      exit 1
  | Some spec ->
      let params = strategy_params_from_args spec args in
      let strat = spec.build params in
      let syn = Synthetic.Synthetic_broker.make () in
      let candles =
        Synthetic.Synthetic_broker.bars syn ~n ~instrument ~timeframe:Timeframe.H1
      in
      let cfg = Engine.Backtest.default_config () in
      let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~instrument ~candles in
      Printf.printf
        "Strategy: %s\n\
         Bars: %d\n\
         Trades: %d\n\
         Total return: %.2f%%\n\
         Max drawdown: %.2f%%\n\
         Realized PnL: %s\n\
         Final cash: %s\n"
        strat_name n r.num_trades (r.total_return *. 100.0) (r.max_drawdown *. 100.0)
        (Decimal.to_string r.final.realized_pnl)
        (Decimal.to_string r.final.cash)

(** Build a {!Server.Http.live_setup} that bridges Finam's WebSocket
    feed into the SSE stream registry. Connection happens up-front on
    the server's switch; per-key SUBSCRIBE/UNSUBSCRIBE messages flow
    on subscriber lifecycle hooks; inbound BARS events fan out via
    [Stream.push_from_upstream]. *)
let finam_live_setup ~env ~paper_sink ~publish_bar_updated (rest : Finam.Rest.t) ~sw :
    Server.Http.live_setup =
  let cfg = Finam.Rest.cfg rest in
  let auth = Finam.Rest.auth rest in
  let registry_ref : Server.Stream.t option ref = ref None in
  (* Forward-declared to break the mutual dependency: the bridge's
     event handler needs to know the bridge to look up active
     timeframes, so we close over a ref that gets set right after
     [make] returns. *)
  let bridge_ref : Finam.Ws_bridge.bridge option ref = ref None in
  let on_event (ev : Finam.Ws.event) =
    match ev with
    | Bars { instrument; timeframe; bars } ->
        List.iter (fun candle -> paper_sink instrument candle) bars;
        let tfs : Timeframe.t list =
          match timeframe with
          | Some tf -> [ tf ]
          | None -> (
              (* No subscription_key in the frame — fall back to the
                 legacy scan of active subs for this instrument. *)
              match !bridge_ref with
              | None -> []
              | Some b -> Finam.Ws_bridge.timeframes_for_instrument b instrument)
        in
        List.iter
          (fun (tf : Timeframe.t) ->
            List.iter
              (fun (candle : Candle.t) ->
                (match !registry_ref with
                | Some r ->
                    Server.Stream.push_from_upstream r ~instrument ~timeframe:tf candle
                | None -> ());
                publish_bar_updated
                  (Broker_integration_events.Bar_updated_integration_event.of_domain
                     ~instrument ~timeframe:tf ~bar:candle))
              bars)
          tfs
    | Error_ev { code; type_; message } ->
        Log.warn "[finam ws] error %d %s: %s" code type_ message
    | Lifecycle { event; code; reason } ->
        Log.info "[finam ws] %s (%d) %s" event code reason
    | _ -> ()
  in
  let bridge = Finam.Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event in
  bridge_ref := Some bridge;
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
    }

(** Build a {!Server.Http.live_setup} for BCS. Unlike Finam, BCS
    opens one socket per subscription, so the bridge defers connect
    to [on_first] and tears down on [on_last]. The BARS fan-out
    callback pushes directly into the registry via
    [Stream.push_from_upstream]. *)
let bcs_live_setup ~env ~paper_sink ~publish_bar_updated (rest : Bcs.Rest.t) ~sw :
    Server.Http.live_setup =
  let cfg = Bcs.Rest.cfg rest in
  let auth = Bcs.Rest.auth rest in
  let bridge = Bcs.Ws_bridge.make ~env ~sw ~cfg ~auth in
  let registry_ref : Server.Stream.t option ref = ref None in
  let push instrument timeframe candle =
    paper_sink instrument candle;
    (match !registry_ref with
    | Some r -> Server.Stream.push_from_upstream r ~instrument ~timeframe candle
    | None -> ());
    publish_bar_updated
      (Broker_integration_events.Bar_updated_integration_event.of_domain ~instrument
         ~timeframe ~bar:candle)
  in
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe ~on_candle:push
          with e -> Log.warn "[bcs ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[bcs ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
    }

let cmd_serve args =
  let port =
    match arg_value "--port" args with
    | Some v -> int_of_string v
    | None -> 8080
  in
  let broker_id =
    match arg_value "--broker" args with
    | Some v -> v
    | None -> "synthetic"
  in
  let prefix = broker_env_prefix broker_id in
  let secret =
    match arg_value "--secret" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_SECRET")
  in
  let account =
    match arg_value "--account" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_ACCOUNT_ID")
  in
  (* BCS-only knob; Finam doesn't have a concept of [client_id] (its
     auth is a single long-lived secret). *)
  let client_id =
    match arg_value "--client-id" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt "BCS_CLIENT_ID"
  in
  let log_level =
    match arg_value "--log-level" args with
    | Some "debug" -> Logs.Debug
    | Some "warning" -> Logs.Warning
    | Some "error" -> Logs.Error
    | _ -> Logs.Info
  in
  Log.setup ~level:log_level ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  (* Finam demands a secret on every boot — it has no persistent store
     of its own and the secret doesn't rotate. BCS reads from its
     [Token_store] chain (file → env) so a missing --secret is fine
     when the file is already populated. *)
  let need_secret () =
    match secret with
    | Some s -> s
    | None ->
        Printf.eprintf "--broker %s requires a secret (use --secret or %s_SECRET)\n"
          broker_id prefix;
        exit 2
  in
  let paper_mode = List.mem "--paper" args in
  let strategy_name = arg_value "--strategy" args in
  let engine_symbol =
    match arg_value "--engine-symbol" args with
    | Some v -> Instrument.of_qualified v
    | None -> Instrument.of_qualified "SBER@MISX"
  in
  let opened =
    match broker_id with
    | "synthetic" -> open_synthetic ()
    | "finam" -> open_finam ~env ~secret:(need_secret ()) ~account
    | "bcs" -> open_bcs ~env ~secret ~account ~client_id
    | other -> failwith ("unknown --broker: " ^ other ^ " (expected synthetic|finam|bcs)")
  in
  let source_client = opened_client opened in
  let paper_t =
    if paper_mode then Some (Paper.Paper_broker.make ~source:source_client ()) else None
  in
  let client =
    match paper_t with
    | Some p -> Paper.Paper_broker.as_broker p
    | None -> source_client
  in
  (* Live engine — optional; constructed only when --strategy is set.
     Trades [engine_symbol] through [client] (which is Paper-wrapped
     when --paper, so engine orders are simulated in that case). *)
  let engine_t =
    match strategy_name with
    | None -> None
    | Some name -> (
        match Strategies.Registry.find name with
        | None ->
            Printf.eprintf "unknown --strategy: %s (use `trading list`)\n" name;
            exit 2
        | Some spec ->
            let strat = spec.build (strategy_params_from_args spec args) in
            let equity = Decimal.of_int 1_000_000 in
            let cfg : Live_engine.config =
              {
                broker = client;
                strategy = strat;
                instrument = engine_symbol;
                initial_cash = equity;
                limits = Engine.Risk.default_limits ~equity;
                tif = Order.DAY;
                fee_rate = Decimal.of_string "0.0005";
                reconcile_every = 10;
                max_drawdown_pct = 0.15;
                rate_limit = None;
              }
            in
            Some (Live_engine.make cfg))
  in
  (* Wire Paper's fill events into Live_engine's reservation ledger.
     In real live trading this will be driven by WS [order_update]
     frames from Finam/BCS instead — Paper is the stand-in with the
     same callback contract. *)
  (match (paper_t, engine_t) with
  | Some p, Some e ->
      Paper.Paper_broker.on_fill p (fun (f : Paper.Paper_broker.fill) ->
          Live_engine.on_fill_event e
            {
              client_order_id = f.client_order_id;
              actual_quantity = f.quantity;
              actual_price = f.price;
              actual_fee = f.fee;
            })
  | _ -> ());
  Log.info "broker: %s%s (account=%s)%s" (Broker.name source_client)
    (if paper_mode then " [paper]" else "")
    (Option.value account ~default:"<none>")
    (match strategy_name with
    | Some n ->
        Printf.sprintf " [engine: %s on %s]" n (Instrument.to_qualified engine_symbol)
    | None -> "");
  (* Inbound ACL handler for [Bar_updated_integration_event]: holds an
     internal Eio.Stream that the bus subscriber pushes to and the
     [Live_engine] fiber pulls from. Constructed before opening the
     switch — [make] does no IO; the dispatch fiber (in In_memory
     adapter) is what actually fires [handle] later, on the server's
     switch. *)
  let engine_handler =
    Option.map
      (fun _ ->
        Strategy_inbound_integration_events.Bar_updated_integration_event_handler.make
          ~capacity:64)
      engine_t
  in
  let paper_sink =
    match paper_t with
    | Some p -> fun instrument candle -> Paper.Paper_broker.on_bar p ~instrument candle
    | None -> fun _ _ -> ()
  in
  (* Wrap any [Server.Http.live_setup] factory so that, when the
     server's switch opens, we also spawn the engine fiber on the
     same switch. Engine's lifetime is thereby tied to the server's
     — shutdown the server, the engine daemon winds down with it. *)
  let with_engine (base : sw:Eio.Switch.t -> Server.Http.live_setup) ~sw :
      Server.Http.live_setup =
    (match (engine_t, engine_handler) with
    | Some e, Some h ->
        Eio.Fiber.fork_daemon ~sw (fun () ->
            Live_engine.run e
              ~source:
                (Strategy_inbound_integration_events.Bar_updated_integration_event_handler
                 .source h);
            `Stop_daemon)
    | _ -> ());
    base ~sw
  in
  Eio.Switch.run @@ fun sw ->
  (* One [Bus.t] per process; one [In_memory] broker registered as the
     ["in-memory"] scheme. Replacing transport later is a one-line
     change to [Bus.register]; nothing else moves. *)
  let bus = Bus.create () in
  let in_memory_broker = In_memory.create ~sw in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter in_memory_broker);
  let producer (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a Bus.producer =
    Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v))
  in
  let consumer (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  (* Outbound producers + port closures for Broker BC. Account's
     three outbound producers live inside [Account_factory.build]
     below — Account is autonomous about how its outbound DTOs hit
     the wire. *)
  let publish_order_accepted =
    Bus.publish
      (producer ~uri:"in-memory://broker.order-accepted"
         ~yojson_of:Broker_integration_events.Order_accepted_integration_event.yojson_of_t)
  in
  let publish_order_rejected =
    Bus.publish
      (producer ~uri:"in-memory://broker.order-rejected"
         ~yojson_of:Broker_integration_events.Order_rejected_integration_event.yojson_of_t)
  in
  let publish_order_unreachable =
    Bus.publish
      (producer ~uri:"in-memory://broker.order-unreachable"
         ~yojson_of:
           Broker_integration_events.Order_unreachable_integration_event.yojson_of_t)
  in
  let publish_bar_updated =
    Bus.publish
      (producer ~uri:"in-memory://broker.bar-updated"
         ~yojson_of:Broker_integration_events.Bar_updated_integration_event.yojson_of_t)
  in
  let dispatch_submit_order =
    Broker_commands.Submit_order_command_handler.make ~broker:client
      ~publish_accepted:publish_order_accepted ~publish_rejected:publish_order_rejected
      ~publish_unreachable:publish_order_unreachable
  in
  ignore dispatch_submit_order
  (* The place-order saga is not yet wired; the dispatch closure is
     held in scope so Submit_order_command_handler is fully
     constructed (typechecked end-to-end) and ready for whoever
     becomes its caller. *);
  (* Strategy-side bar handler: read broker's bar-updated URI with
     Strategy's mirror DTO deserializer, push decoded candles to the
     handler's internal stream which Live_engine.run consumes. *)
  (match engine_handler with
  | Some h ->
      let _ : Bus.subscription =
        Bus.subscribe
          (consumer ~uri:"in-memory://broker.bar-updated" ~group:"strategy-engine"
             ~t_of_yojson:
               Strategy_inbound_integration_events.Bar_updated_integration_event
               .t_of_yojson)
          (Strategy_inbound_integration_events.Bar_updated_integration_event_handler
           .handle h ~instrument:engine_symbol)
      in
      ()
  | None -> ());
  let market_price ~instrument =
    match Broker.bars client ~n:1 ~instrument ~timeframe:Timeframe.H1 with
    | last :: _ -> last.close
    | [] -> Decimal.zero
  in
  let account =
    Account_factory.Factory.build ~bus ~initial_cash:(Decimal.of_int 1_000_000)
      ~market_price
  in
  let bc_handlers = [ account.http_handler ] in
  let ws_setup =
    match opened with
    | Opened_finam { rest; _ } ->
        Some (with_engine (finam_live_setup ~env ~paper_sink ~publish_bar_updated rest))
    | Opened_bcs { rest; _ } ->
        Some (with_engine (bcs_live_setup ~env ~paper_sink ~publish_bar_updated rest))
    | Opened_synthetic _ -> None
  in
  (* SSE projector subscribers: each event type gets its own consumer
     in group "sse-publisher" with the publisher-side DTO
     deserializer. SSE is part of the same logical "Trading host"
     deployment as Broker/Account so it legitimately imports their
     outbound types. *)
  let register_publisher (registry : Server.Stream.t) =
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://account.amount-reserved" ~group:"sse-publisher"
           ~t_of_yojson:
             Account_integration_events.Amount_reserved_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_amount_reserved ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://account.reservation-released" ~group:"sse-publisher"
           ~t_of_yojson:
             Account_integration_events.Reservation_released_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_reservation_released ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://account.reservation-rejected" ~group:"sse-publisher"
           ~t_of_yojson:
             Account_integration_events.Reservation_rejected_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_reservation_rejected ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://broker.order-accepted" ~group:"sse-publisher"
           ~t_of_yojson:
             Broker_integration_events.Order_accepted_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_order_accepted ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://broker.order-rejected" ~group:"sse-publisher"
           ~t_of_yojson:
             Broker_integration_events.Order_rejected_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_order_rejected ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://broker.order-unreachable" ~group:"sse-publisher"
           ~t_of_yojson:
             Broker_integration_events.Order_unreachable_integration_event.t_of_yojson)
        (Server.Publish_order_events.handle_order_unreachable ~registry)
    in
    ()
  in
  Log.info "listening on http://127.0.0.1:%d (%s)" port (Broker.name client);
  Server.Http.run ?setup:ws_setup ~bc_handlers ~sw ~env ~port ~broker:client
    ~register_publisher ()

(** Tiny HTTP client for the [orders] subcommand. Talks to a running
    server (default http://localhost:8080); the same surface the UI
    consumes, so CLI and UI share the same Paper-vs-live semantics. *)
let api_url host path = Uri.of_string (host ^ path)

let api_request ~env ~host ~meth ?body path : Yojson.Safe.t =
  let transport = Http_transport.make_eio ~env in
  let headers =
    [ ("Content-Type", "application/json"); ("Accept", "application/json") ]
  in
  let resp = transport { meth; url = api_url host path; headers; body } in
  if resp.status >= 200 && resp.status < 300 then Yojson.Safe.from_string resp.body
  else begin
    Printf.eprintf "HTTP %d: %s\n" resp.status resp.body;
    exit 1
  end

let format_order (j : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  let cid = j |> member "client_order_id" |> to_string in
  let symbol = j |> member "instrument" |> to_string in
  let side = j |> member "side" |> to_string in
  let qty = j |> member "quantity" |> to_string in
  let filled = j |> member "filled" |> to_string in
  let status = j |> member "status" |> to_string in
  let kind = j |> member "kind" |> member "type" |> to_string in
  Printf.sprintf "%-24s %-14s %-4s qty=%-8s filled=%-8s %-6s %s" cid symbol side qty
    filled kind status

let cmd_orders_list ~env ~host () =
  let j = api_request ~env ~host ~meth:`GET "/api/orders" in
  let orders = Yojson.Safe.Util.(j |> member "orders" |> to_list) in
  if orders = [] then print_endline "(no orders)"
  else List.iter (fun o -> print_endline (format_order o)) orders

let cmd_orders_get ~env ~host cid =
  let j = api_request ~env ~host ~meth:`GET ("/api/orders/" ^ cid) in
  print_endline (format_order j)

let cmd_orders_place ~env ~host args =
  let get name =
    match arg_value ("--" ^ name) args with
    | Some v -> v
    | None ->
        Printf.eprintf "missing --%s\n" name;
        exit 2
  in
  let optional name = arg_value ("--" ^ name) args in
  let body_fields =
    [
      ("symbol", `String (get "symbol"));
      ("side", `String (String.uppercase_ascii (get "side")));
      ("quantity", `String (get "qty"));
      ("client_order_id", `String (get "cid"));
      ("tif", `String (Option.value (optional "tif") ~default:"DAY"));
    ]
  in
  let kind : Yojson.Safe.t =
    let k = String.uppercase_ascii (Option.value (optional "kind") ~default:"MARKET") in
    match k with
    | "MARKET" -> `Assoc [ ("type", `String "MARKET") ]
    | "LIMIT" -> `Assoc [ ("type", `String "LIMIT"); ("price", `String (get "price")) ]
    | "STOP" -> `Assoc [ ("type", `String "STOP"); ("price", `String (get "price")) ]
    | "STOP_LIMIT" ->
        `Assoc
          [
            ("type", `String "STOP_LIMIT");
            ("stop_price", `String (get "stop"));
            ("limit_price", `String (get "price"));
          ]
    | other ->
        Printf.eprintf "unknown --kind %s\n" other;
        exit 2
  in
  let payload : Yojson.Safe.t = `Assoc (body_fields @ [ ("kind", kind) ]) in
  let body = Yojson.Safe.to_string payload in
  let j = api_request ~env ~host ~meth:`POST ~body "/api/orders" in
  print_endline (format_order j)

let cmd_orders_cancel ~env ~host cid =
  let j = api_request ~env ~host ~meth:`DELETE ("/api/orders/" ^ cid) in
  print_endline (format_order j)

let cmd_orders args =
  let host = Option.value (arg_value "--host" args) ~default:"http://localhost:8080" in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  match args with
  | "list" :: _ -> cmd_orders_list ~env ~host ()
  | "get" :: cid :: _ -> cmd_orders_get ~env ~host cid
  | "place" :: rest -> cmd_orders_place ~env ~host rest
  | "cancel" :: cid :: _ -> cmd_orders_cancel ~env ~host cid
  | _ ->
      prerr_endline
        {|orders <list|get|place|cancel> [--host http://localhost:8080]

  list                     list all orders on the running server
  get <cid>                fetch one order by client_order_id
  place --symbol SBER@MISX --side BUY --qty 10 --cid my-cid
        [--kind MARKET|LIMIT|STOP|STOP_LIMIT]
        [--price PRICE] [--stop PRICE] [--tif DAY|GTC|IOC|FOK]
  cancel <cid>             cancel by client_order_id|};
      exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: "list" :: _ -> cmd_list ()
  | _ :: "backtest" :: rest -> cmd_backtest rest
  | _ :: "serve" :: rest -> cmd_serve rest
  | _ :: "orders" :: rest -> cmd_orders rest
  | _ -> usage ()

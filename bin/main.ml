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

      trading backtest <strategy> [--n N] [--symbol SBER@MISX]
                                   [--param KEY=VALUE ...]
        run the same in-process composition that powers [serve], with
        the synthetic broker as data source and paper-mode order
        interception, then report counters tallied from the saga's
        outbound integration events. *)

open Core

(** Locate the value following a CLI flag (e.g. ["--port" "8080"]
    returns [Some "8080"]). Single-value variant; {!arg_values}
    below collects every value for repeated flags. *)
let arg_value name args =
  let rec find = function
    | k :: v :: _ when k = name -> Some v
    | _ :: rest -> find rest
    | [] -> None
  in
  find args

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

  orders <place> [--host http://localhost:8080]
      start a placement saga against a running `serve` instance
      (Account's POST /api/orders entry point). The list/get/cancel
      subcommands have been removed — venue-keyed UI is no longer
      surfaced by broker BC; order identity in our model is the
      placement_id, which lives on the bus. Run `orders` with no
      subcommand for per-action flags.
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

type backtest_summary = {
  strategy_name : string;
  symbol : Instrument.t;
  candles : int;
  signals : int;
  intents_planned : int;
  intents_approved : int;
  intents_rejected : int;
  amounts_reserved : int;
  reservations_rejected : int;
  orders_accepted : int;
  orders_rejected : int;
  orders_unreachable : int;
  submissions_blocked : int;
  paper_cash : Decimal.t option;
  realized_pnl : Decimal.t option;
}
(** Backtest via composition: boot the same in-process trading host
    used by [serve], substitute the synthetic broker as data source
    with paper-mode order interception, generate [n] synthetic candles,
    drive them through the broker's bar-updated topic, and tally the
    outbound integration events produced by the saga. No dedicated
    [Backtest.run] domain function exists any more; equivalence to
    live is enforced by running the live composition itself. *)

let run_backtest_composition ~env ~sw ~strategy ~strategy_name ~n ~symbol :
    backtest_summary =
  let bus = Bus.create () in
  let in_memory_broker = In_memory.create ~sw in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter in_memory_broker);
  (* Backtest deployment: virtual clock subscribed to the bar
     stream so ambient time follows the simulated timeline rather
     than the host's wall clock. See ADR 0013. *)
  let virtual_clock = Datetime.Virtual_clock.make () in
  let now () = Datetime.Clock.now (Datetime.Virtual_clock.as_clock virtual_clock) in
  let _ : Bus.subscription =
    let bar_consumer =
      Bus.consumer bus ~uri:"in-memory://broker.bar-updated" ~group:"clock-tick"
        ~deserialize:Yojson.Safe.from_string
    in
    Bus.subscribe bar_consumer (fun (j : Yojson.Safe.t) ->
        match j with
        | `Assoc fields -> (
            match List.assoc_opt "candle" fields with
            | Some (`Assoc candle_fields) -> (
                match List.assoc_opt "ts" candle_fields with
                | Some (`String ts) ->
                    Datetime.Virtual_clock.set virtual_clock (Datetime.Iso8601.parse ts)
                | _ -> ())
            | _ -> ())
        | _ -> ())
  in
  let opened = Broker_factory.Factory.Opened.open_synthetic () in
  let broker =
    Broker_factory.Factory.build ~bus ~env ~sw ~now ~opened ~paper_mode:true ~watchlist:[]
  in
  let _paper_broker =
    Paper_broker_factory.Factory.build ~bus ~now
      ~slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.zero
      ~fee_rate:Paper_broker.Fee.Values.Fee_rate.zero ()
  in
  let account =
    Account_factory.Factory.build ~bus ~initial_cash:(Decimal.of_int 1_000_000)
      ~market_price:broker.market_price
  in
  let _pm = Portfolio_management_factory.Factory.build ~bus ~now in
  let _pre_trade_risk =
    Pre_trade_risk_factory.Factory.build ~bus ~now
      ~config:
        {
          initial_equity = Decimal.of_int 1_000_000;
          max_drawdown_pct = 0.15;
          rate_limit = None;
        }
  in
  let _order_management = Order_management_factory.Factory.build ~bus in
  let _execution_management = Execution_management_factory.Factory.build ~bus ~now in
  let _strategy =
    Strategy_factory.Factory.build ~bus ~sw ~strategy:(Some strategy)
      ~strategy_id:strategy_name ~engine_symbol:symbol
  in
  (* Outcome counters. The saga publishes its progression through
     these topics; tallying their cardinality yields the post-run
     summary that used to come from [Engine.Backtest.run]. *)
  let signals = ref 0 in
  let intents_planned = ref 0 in
  let intents_approved = ref 0 in
  let intents_rejected = ref 0 in
  let amounts_reserved = ref 0 in
  let reservations_rejected = ref 0 in
  let orders_accepted = ref 0 in
  let orders_rejected = ref 0 in
  let orders_unreachable = ref 0 in
  let submissions_blocked = ref 0 in
  let consume ~uri ~group = Bus.consumer bus ~uri ~group ~deserialize:Fun.id in
  let count r = Bus.subscribe (consume ~uri:r ~group:"backtest-collector") in
  let _ : Bus.subscription =
    count "in-memory://strategy.signal-detected" (fun _ -> incr signals)
  in
  let _ : Bus.subscription =
    count "in-memory://pm.trade-intents-planned" (fun _ -> incr intents_planned)
  in
  let _ : Bus.subscription =
    count "in-memory://pre-trade-risk.trade-intent-approved" (fun _ ->
        incr intents_approved)
  in
  let _ : Bus.subscription =
    count "in-memory://pre-trade-risk.trade-intent-rejected" (fun _ ->
        incr intents_rejected)
  in
  let _ : Bus.subscription =
    count "in-memory://account.amount-reserved" (fun _ -> incr amounts_reserved)
  in
  let _ : Bus.subscription =
    count "in-memory://account.reservation-rejected" (fun _ -> incr reservations_rejected)
  in
  let _ : Bus.subscription =
    count "in-memory://broker.order-accepted" (fun _ -> incr orders_accepted)
  in
  let _ : Bus.subscription =
    count "in-memory://broker.order-rejected" (fun _ -> incr orders_rejected)
  in
  let _ : Bus.subscription =
    count "in-memory://broker.order-unreachable" (fun _ -> incr orders_unreachable)
  in
  let _ : Bus.subscription =
    count "in-memory://pre-trade-risk.trade-submission-blocked" (fun _ ->
        incr submissions_blocked)
  in
  let candles_list =
    Synthetic.Generator.generate ~n ~start_ts:0L ~tf_seconds:300 ~start_price:100.0
  in
  let publish_bar_updated =
    Bus.publish
      (Bus.producer bus ~uri:"in-memory://broker.bar-updated" ~serialize:(fun v ->
           Yojson.Safe.to_string
             (Broker_integration_events.Bar_updated_integration_event.yojson_of_t v)))
  in
  (* Each candle takes one trip through:
     bar-updated → strategy → signal-detected → PM → trade-intents-planned
     → pre_trade_risk → trade-intent-approved → execution_management
     → reserve-command → account → amount-reserved → execution_management
     → submit-order-command → paper_broker → order-accepted/filled
     → account → reservation-filled (terminal). Each hop is one fiber
     yield in the in_memory bus, so a generous yield count after each
     bar lets the saga settle before the next bar arrives. *)
  let drain () =
    for _ = 1 to 32 do
      Eio.Fiber.yield ()
    done
  in
  List.iter
    (fun candle ->
      publish_bar_updated
        (Broker_integration_events.Bar_updated_integration_event.of_domain
           {
             Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument = symbol;
             timeframe = Timeframe.M5;
             candle;
           });
      drain ())
    candles_list;
  drain ();
  let portfolio = account.portfolio_snapshot () in
  let paper_cash = Some portfolio.cash in
  let realized_pnl = Some portfolio.realized_pnl in
  {
    strategy_name;
    symbol;
    candles = n;
    signals = !signals;
    intents_planned = !intents_planned;
    intents_approved = !intents_approved;
    intents_rejected = !intents_rejected;
    amounts_reserved = !amounts_reserved;
    reservations_rejected = !reservations_rejected;
    orders_accepted = !orders_accepted;
    orders_rejected = !orders_rejected;
    orders_unreachable = !orders_unreachable;
    submissions_blocked = !submissions_blocked;
    paper_cash;
    realized_pnl;
  }

(** Decode strategy parameters from a JSON object against the spec's
    declared types. Mirrors {!parse_strategy_param} for the CLI: type
    is taken from [spec.params], the inbound value is coerced; unknown
    keys are rejected. JSON booleans / strings / ints / floats are
    accepted in the obvious way. *)
let strategy_params_from_json (spec : Strategies.Registry.spec) (j : Yojson.Safe.t) :
    (string * Strategies.Registry.param) list =
  match j with
  | `Null -> []
  | `Assoc kvs ->
      List.map
        (fun (k, v) ->
          match List.assoc_opt k spec.params with
          | None ->
              invalid_arg
                (Printf.sprintf "unknown param %S for strategy %S (expected one of: %s)" k
                   spec.name
                   (String.concat ", " (List.map fst spec.params)))
          | Some (Strategies.Registry.Int _) -> (
              match v with
              | `Int n -> (k, Strategies.Registry.Int n)
              | `Intlit s -> (k, Strategies.Registry.Int (int_of_string s))
              | _ -> invalid_arg (Printf.sprintf "param %S: expected int" k))
          | Some (Strategies.Registry.Float _) -> (
              match v with
              | `Float f -> (k, Strategies.Registry.Float f)
              | `Int n -> (k, Strategies.Registry.Float (float_of_int n))
              | _ -> invalid_arg (Printf.sprintf "param %S: expected float" k))
          | Some (Strategies.Registry.Bool _) -> (
              match v with
              | `Bool b -> (k, Strategies.Registry.Bool b)
              | _ -> invalid_arg (Printf.sprintf "param %S: expected bool" k))
          | Some (Strategies.Registry.String _) -> (
              match v with
              | `String s -> (k, Strategies.Registry.String s)
              | _ -> invalid_arg (Printf.sprintf "param %S: expected string" k)))
        kvs
  | _ -> invalid_arg "params: expected object"

let backtest_summary_to_json (s : backtest_summary) : Yojson.Safe.t =
  let dec_field v =
    match v with
    | Some d -> `String (Decimal.to_string d)
    | None -> `Null
  in
  `Assoc
    [
      ("strategy", `String s.strategy_name);
      ("symbol", `String (Instrument.to_qualified s.symbol));
      ("candles", `Int s.candles);
      ("signals", `Int s.signals);
      ("intents_planned", `Int s.intents_planned);
      ("intents_approved", `Int s.intents_approved);
      ("intents_rejected", `Int s.intents_rejected);
      ("amounts_reserved", `Int s.amounts_reserved);
      ("reservations_rejected", `Int s.reservations_rejected);
      ("orders_accepted", `Int s.orders_accepted);
      ("orders_rejected", `Int s.orders_rejected);
      ("orders_unreachable", `Int s.orders_unreachable);
      ("submissions_blocked", `Int s.submissions_blocked);
      ("paper_cash", dec_field s.paper_cash);
      ("realized_pnl", dec_field s.realized_pnl);
    ]

(** Build a route handler for [POST /api/backtest]. The closure
    captures [env] from the live serving switch; per-request work
    runs on a fresh inner [Eio.Switch.run] so backtest fibers,
    in-memory broker subscriptions, and HTTP-server fibers stay
    isolated. Body shape:
      { "strategy": "SMA_Crossover",
        "n": 200,
        "symbol": "SBER@MISX",
        "params": { "fast": 10, "slow": 30 } }
    Defaults match {!cmd_backtest}. *)
let make_backtest_handler ~env : Inbound_http.Route.handler =
 fun request body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `POST, "/api/backtest" -> (
      try
        let body_str = Eio.Flow.read_all body in
        let j = Yojson.Safe.from_string body_str in
        let open Yojson.Safe.Util in
        let strategy_name = j |> member "strategy" |> to_string in
        let n =
          match j |> member "n" with
          | `Null -> 200
          | `Int i -> i
          | _ -> failwith "n"
        in
        let symbol =
          match j |> member "symbol" with
          | `Null -> Instrument.of_qualified "SBER@MISX"
          | `String s -> Instrument.of_qualified s
          | _ -> failwith "symbol"
        in
        let spec =
          match Strategies.Registry.find strategy_name with
          | Some s -> s
          | None -> invalid_arg ("unknown strategy: " ^ strategy_name)
        in
        let params = strategy_params_from_json spec (member "params" j) in
        let strategy = spec.build params in
        let summary =
          Eio.Switch.run @@ fun sw ->
          run_backtest_composition ~env ~sw ~strategy ~strategy_name ~n ~symbol
        in
        Some
          (200, `Response (Inbound_http.Response.json (backtest_summary_to_json summary)))
      with e ->
        Some
          ( 400,
            `Response
              (Inbound_http.Response.json ~status:`Bad_request
                 (`Assoc [ ("error", `String (Printexc.to_string e)) ])) ))
  | _ -> None

(* Build a sparse Trading_config.t carrying only the CLI flags
   the operator explicitly passed. None at every field means
   "don't override" — the loader merges this overlay on top of
   default.config.json, local.config.json, and env vars. *)
let cli_overlay_of_args (args : string list) : Trading_config.t =
  let parse_log_level = function
    | "debug" -> Some `Debug
    | "info" -> Some `Info
    | "warning" | "warn" -> Some `Warning
    | "error" -> Some `Error
    | _ -> None
  in
  let server : Trading_config.server option =
    let host = arg_value "--host" args in
    let port = arg_value "--port" args |> Option.map int_of_string in
    if host = None && port = None then None else Some { host; port }
  in
  let engine : Trading_config.engine option =
    let strategy = arg_value "--strategy" args in
    let symbol = arg_value "--engine-symbol" args in
    let paper_mode = if List.mem "--paper" args then Some true else None in
    if strategy = None && symbol = None && paper_mode = None then None
    else Some { strategy; symbol; paper_mode }
  in
  let logging : Trading_config.logging option =
    match arg_value "--log-level" args with
    | None -> None
    | Some s -> (
        match parse_log_level s with
        | None -> None
        | Some level -> Some { level = Some level })
  in
  let broker : Trading_config.broker option =
    (* --broker on the CLI selects the variant; --secret /
       --account / --client-id fill in the credentials. None
       overrides nothing — broker stays as configured in the
       lower layers. *)
    match arg_value "--broker" args with
    | None -> None
    | Some "synthetic" -> Some `Synthetic
    | Some "finam" ->
        let creds : Trading_config.finam_credentials =
          { account_id = arg_value "--account" args; secret = arg_value "--secret" args }
        in
        Some (`Finam creds)
    | Some "bcs" ->
        let creds : Trading_config.bcs_credentials =
          {
            client_id = arg_value "--client-id" args;
            secret_seed = arg_value "--secret" args;
          }
        in
        Some (`Bcs creds)
    | Some other ->
        failwith ("unknown --broker: " ^ other ^ " (expected synthetic|finam|bcs)")
  in
  (* CLI overlay never declares a watchlist — the operator should
     express bar subscriptions in a config file, not on the
     command line. *)
  { broker; server; engine; watchlist = None; logging }

let config_default_path = "config/default.config.json"
let config_env_var = "TRADING_CONFIG"

let logs_level_of_config : Trading_config.log_level -> Logs.level = function
  | `Debug -> Logs.Debug
  | `Info -> Logs.Info
  | `Warning -> Logs.Warning
  | `Error -> Logs.Error

let cmd_serve args =
  let cli_overrides = cli_overlay_of_args args in
  let local_path = arg_value "--config" args in
  let cfg =
    Trading_config.Loader.load ~default_path:config_default_path ?local_path
      ~env_var:config_env_var ~cli_overrides ()
  in
  let server : Trading_config.server =
    Option.value cfg.server ~default:{ host = None; port = None }
  in
  let port = Option.value server.port ~default:8080 in
  let engine : Trading_config.engine =
    Option.value cfg.engine ~default:{ strategy = None; symbol = None; paper_mode = None }
  in
  let paper_mode = Option.value engine.paper_mode ~default:false in
  let strategy_name = engine.strategy in
  let broker_choice : Trading_config.broker =
    Option.value cfg.broker ~default:`Synthetic
  in
  let broker_id =
    match broker_choice with
    | `Synthetic -> "synthetic"
    | `Finam _ -> "finam"
    | `Bcs _ -> "bcs"
  in
  let secret, account, client_id =
    match broker_choice with
    | `Synthetic -> (None, None, None)
    | `Finam creds -> (creds.secret, creds.account_id, None)
    | `Bcs creds -> (creds.secret_seed, None, creds.client_id)
    (* BCS has no account_id parameter at the API level; the
       middle slot here is uniformly None so the surrounding
       open_bcs ?account_id receives nothing to forward. *)
  in
  let log_level =
    match cfg.logging with
    | Some { level = Some level } -> logs_level_of_config level
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
        let prefix = String.uppercase_ascii broker_id in
        Printf.eprintf
          "--broker %s requires a secret (use --secret, %s_SECRET, or the config file)\n"
          broker_id prefix;
        exit 2
  in
  let engine_symbol =
    match engine.symbol with
    | Some v -> Instrument.of_qualified v
    | None -> Instrument.of_qualified "SBER@MISX"
  in
  let opened =
    match broker_id with
    | "synthetic" -> Broker_factory.Factory.Opened.open_synthetic ()
    | "finam" ->
        let account_id =
          match account with
          | Some a -> a
          | None ->
              Printf.eprintf "--broker finam requires --account (or FINAM_ACCOUNT_ID)\n";
              exit 2
        in
        Broker_factory.Factory.Opened.open_finam ~env ~secret:(need_secret ()) ~account_id
    | "bcs" ->
        Broker_factory.Factory.Opened.open_bcs ~env ?secret ?account_id:account ?client_id
          ()
    | other -> failwith ("unknown --broker: " ^ other ^ " (expected synthetic|finam|bcs)")
  in
  let source_client = Broker_factory.Factory.Opened.client opened in
  (* Resolve [--strategy] CLI arg into a built [Strategies.Strategy.t].
     Registry lookup and per-strategy [--param] parsing stay in the
     composition root; the actual engine construction lives in
     {!Strategy_factory.Factory.build} below. *)
  let resolved_strategy =
    match strategy_name with
    | None -> None
    | Some name -> (
        match Strategies.Registry.find name with
        | None ->
            Printf.eprintf "unknown --strategy: %s (use `trading list`)\n" name;
            exit 2
        | Some spec -> Some (spec.build (strategy_params_from_args spec args)))
  in
  Log.info "broker: %s%s (account=%s)%s" (Broker.name source_client)
    (if paper_mode then " [paper]" else "")
    (Option.value account ~default:"<none>")
    (match strategy_name with
    | Some n ->
        Printf.sprintf " [engine: %s on %s]" n (Instrument.to_qualified engine_symbol)
    | None -> "");
  Eio.Switch.run @@ fun sw ->
  (* One [Bus.t] per process; one [In_memory] broker registered as
     the ["in-memory"] scheme. Replacing transport later is a one-
     line change to [Bus.register]; nothing else moves. *)
  let bus = Bus.create () in
  let in_memory_broker = In_memory.create ~sw in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter in_memory_broker);
  (* Live deployment: wall-clock for any Application-Layer caller
     that needs ambient time. See ADR 0013. *)
  let clock = Datetime.Unix_clock.make () in
  let now () = Datetime.Clock.now clock in
  let consumer (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  (* Parse the operator-declared watchlist from config strings into
     domain types here at the composition root; the broker factory
     consumes already-typed (instrument, timeframe) pairs and is the
     one that calls Broker.subscribe. Unparseable entries are warned
     and dropped — a typo must not block the host from starting. *)
  let watchlist_bars =
    let raw =
      match cfg.watchlist with
      | Some { bars = Some xs } -> xs
      | _ -> []
    in
    List.filter_map
      (fun (b : Trading_config.bar_subscription) ->
        match
          ( (try Some (Instrument.of_qualified b.symbol) with _ -> None),
            try Some (Timeframe.of_string b.timeframe) with _ -> None )
        with
        | None, _ ->
            Log.warn "watchlist: unparseable symbol %S — skipping" b.symbol;
            None
        | _, None ->
            Log.warn "watchlist: unknown timeframe %S for %s — skipping" b.timeframe
              b.symbol;
            None
        | Some instrument, Some timeframe -> Some (instrument, timeframe))
      raw
  in
  let broker =
    Broker_factory.Factory.build ~bus ~env ~sw ~now ~opened ~paper_mode
      ~watchlist:watchlist_bars
  in
  let _paper_broker =
    if paper_mode then
      Some
        (Paper_broker_factory.Factory.build ~bus ~now
           ~slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.zero
           ~fee_rate:Paper_broker.Fee.Values.Fee_rate.zero ())
    else None
  in
  let strategy_id_of_resolved =
    match strategy_name with
    | Some n -> n
    | None -> "<none>"
  in
  let strategy =
    Strategy_factory.Factory.build ~bus ~sw ~strategy:resolved_strategy
      ~strategy_id:strategy_id_of_resolved ~engine_symbol
  in
  (* After M5: Strategy is alpha-only. Paper's fill events no longer
     have a destination on the Strategy side — order placement runs
     through the Order_process_manager saga in execution_management.
     Account/Broker bus consumers for Reserve/Submit aren't wired
     yet, so end-to-end traffic is still inert; the wiring is
     structurally complete and waits for those final hops. *)
  let account =
    Account_factory.Factory.build ~bus ~initial_cash:(Decimal.of_int 1_000_000)
      ~market_price:broker.market_price
  in
  let pm = Portfolio_management_factory.Factory.build ~bus ~now in
  let pre_trade_risk =
    Pre_trade_risk_factory.Factory.build ~bus ~now
      ~config:
        {
          initial_equity = Decimal.of_int 1_000_000;
          max_drawdown_pct = 0.15;
          rate_limit = None;
        }
  in
  let order_management = Order_management_factory.Factory.build ~bus in
  let execution_management = Execution_management_factory.Factory.build ~bus ~now in
  let bc_handlers =
    [
      account.http_handler;
      broker.http_handler;
      pm.http_handler;
      pre_trade_risk.http_handler;
      order_management.http_handler;
      execution_management.http_handler;
      strategy.http_handler;
      make_backtest_handler ~env;
    ]
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
             Server_external_integration_events.Order_accepted_integration_event
             .t_of_yojson)
        (Server.Publish_order_events.handle_order_accepted ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://broker.order-rejected" ~group:"sse-publisher"
           ~t_of_yojson:
             Server_external_integration_events.Order_rejected_integration_event
             .t_of_yojson)
        (Server.Publish_order_events.handle_order_rejected ~registry)
    in
    let _ : Bus.subscription =
      Bus.subscribe
        (consumer ~uri:"in-memory://broker.order-unreachable" ~group:"sse-publisher"
           ~t_of_yojson:
             Server_external_integration_events.Order_unreachable_integration_event
             .t_of_yojson)
        (Server.Publish_order_events.handle_order_unreachable ~registry)
    in
    ()
  in
  Log.info "listening on http://127.0.0.1:%d (%s)" port (Broker.name broker.client);
  (* Bar-subscription port: SSE clients arriving / leaving
     publish [Watch_bars_command] / [Unwatch_bars_command] on
     the bus; the broker BC subscribes to those topics and
     forwards them to its refcounted port. No direct call from
     ./lib into broker BC. *)
  let bar_subscription : Server_application_ports.Bar_subscription.t =
    {
      watch = Server_external_commands.Watch_bars_command_sender.make ~bus;
      unwatch = Server_external_commands.Unwatch_bars_command_sender.make ~bus;
    }
  in
  Server.Http.run ~bar_subscription ~bc_handlers ~sw ~env ~port ~bus ~broker:broker.client
    ~register_publisher ()

let cmd_backtest args =
  let strategy_name =
    match List.find_opt (fun s -> String.length s > 0 && s.[0] <> '-') args with
    | Some name -> name
    | None ->
        prerr_endline "backtest: missing strategy name (see `trading list`)";
        exit 2
  in
  let n =
    match arg_value "--n" args with
    | Some v -> int_of_string v
    | None -> 200
  in
  let symbol =
    match arg_value "--symbol" args with
    | Some v -> Instrument.of_qualified v
    | None -> Instrument.of_qualified "SBER@MISX"
  in
  let spec =
    match Strategies.Registry.find strategy_name with
    | Some s -> s
    | None ->
        Printf.eprintf "unknown strategy: %s (use `trading list`)\n" strategy_name;
        exit 2
  in
  let strategy = spec.build (strategy_params_from_args spec args) in
  Log.setup ~level:Logs.Warning ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  let s = run_backtest_composition ~env ~sw ~strategy ~strategy_name ~n ~symbol in
  Printf.printf "backtest: strategy=%s symbol=%s candles=%d\n" s.strategy_name
    (Instrument.to_qualified s.symbol)
    s.candles;
  Printf.printf "  signals_emitted=%d\n" s.signals;
  Printf.printf "  intents: planned=%d approved=%d rejected=%d\n" s.intents_planned
    s.intents_approved s.intents_rejected;
  Printf.printf "  reservations: ok=%d rejected=%d\n" s.amounts_reserved
    s.reservations_rejected;
  Printf.printf "  orders: accepted=%d rejected=%d unreachable=%d\n" s.orders_accepted
    s.orders_rejected s.orders_unreachable;
  Printf.printf "  submissions_blocked=%d\n" s.submissions_blocked;
  match (s.paper_cash, s.realized_pnl) with
  | Some c, Some r ->
      Printf.printf "  paper_cash=%s realized_pnl=%s\n" (Decimal.to_string c)
        (Decimal.to_string r)
  | _ -> ()

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

let orders_removed_msg =
  "orders list/get/cancel: removed. The venue-keyed broker HTTP UI is gone — order \
   identity in this BC is placement_id, which lives only on the bus. Use `orders place` \
   (still talks to Account's HTTP saga entry-point)."

let cmd_orders_list ~env:_ ~host:_ () =
  prerr_endline orders_removed_msg;
  exit 2

let cmd_orders_get ~env:_ ~host:_ _cid =
  prerr_endline orders_removed_msg;
  exit 2

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

let cmd_orders_cancel ~env:_ ~host:_ _cid =
  prerr_endline orders_removed_msg;
  exit 2

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

  list                     [removed] use the bus or Account HTTP read paths
  get <cid>                [removed] client_order_id no longer crosses BC boundaries
  place --symbol SBER@MISX --side BUY --qty 10 --cid my-cid
        [--kind MARKET|LIMIT|STOP|STOP_LIMIT]
        [--price PRICE] [--stop PRICE] [--tif DAY|GTC|IOC|FOK]
  cancel <cid>             [removed] same reason as get/list|};
      exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: "list" :: _ -> cmd_list ()
  | _ :: "serve" :: rest -> cmd_serve rest
  | _ :: "backtest" :: rest -> cmd_backtest rest
  | _ :: "orders" :: rest -> cmd_orders rest
  | _ -> usage ()

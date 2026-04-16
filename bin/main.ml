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

let usage () =
  prerr_endline {|trading <command> [options]

  serve [--port 8080] [--live] [--broker finam|bcs]
        [--secret SECRET] [--account ACCOUNT_ID]
      start HTTP API server (bound to localhost).
      Default mode is synthetic. Pass --live to hit a real broker.
      --broker selects which integration (default: finam). Secret /
      account may also come from <BROKER>_SECRET / <BROKER>_ACCOUNT_ID
      env vars, e.g. FINAM_SECRET, BCS_SECRET.

  list
      show registered indicators and strategies

  backtest <strategy> [--n N] [--symbol SBER]
      run a backtest on synthetic data and print summary
|};
  exit 2

let cmd_list () =
  print_endline "Indicators:";
  List.iter (fun s -> Printf.printf "  - %s\n" s.Indicators.Registry.name)
    Indicators.Registry.specs;
  print_endline "Strategies:";
  List.iter (fun s -> Printf.printf "  - %s\n" s.Strategies.Registry.name)
    Strategies.Registry.specs

let cmd_backtest args =
  let strat_name = match args with
    | n :: _ -> n | [] -> usage () in
  let n =
    let rec find = function
      | "--n" :: v :: _ -> int_of_string v
      | _ :: rest -> find rest
      | [] -> 500
    in find args in
  let instrument =
    let rec find = function
      | "--symbol" :: v :: _ -> Instrument.of_qualified v
      | _ :: rest -> find rest
      | [] -> Instrument.of_qualified "SBER@MISX"
    in find args in
  match Strategies.Registry.find strat_name with
  | None ->
    Printf.eprintf "unknown strategy %s\n" strat_name;
    exit 1
  | Some spec ->
    let strat = spec.build [] in
    let candles = Server.Synthetic.generate
      ~n ~start_ts:1_704_067_200L ~tf_seconds:3600 ~start_price:100.0 in
    let cfg = Engine.Backtest.default_config () in
    let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~instrument ~candles in
    Printf.printf "Strategy: %s\nBars: %d\nTrades: %d\n\
                   Total return: %.2f%%\nMax drawdown: %.2f%%\n\
                   Realized PnL: %s\nFinal cash: %s\n"
      strat_name n r.num_trades
      (r.total_return *. 100.0) (r.max_drawdown *. 100.0)
      (Decimal.to_string r.final.realized_pnl)
      (Decimal.to_string r.final.cash)

let arg_value name args =
  let rec find = function
    | k :: v :: _ when k = name -> Some v
    | _ :: rest -> find rest
    | [] -> None
  in find args

let arg_flag name args = List.mem name args

(** Selects the secret / account env-var prefix per broker. Keeps the
    CLI single-flagged while letting users park credentials for
    multiple brokers side by side. *)
let broker_env_prefix = function
  | "bcs" -> "BCS"
  | _ -> "FINAM"

let open_finam ~env ~secret ~account : Broker.client =
  let cfg = Finam.Config.make ?account_id:account ~secret () in
  let transport = Http_transport.make_eio ~env in
  let rest = Finam.Rest.make ~transport ~cfg in
  Finam.Finam_broker.as_broker rest

let open_bcs ~env ~secret ~account : Broker.client =
  let cfg = Bcs.Config.make ?account_id:account ~refresh_token:secret () in
  let transport = Http_transport.make_eio ~env in
  let rest = Bcs.Rest.make ~transport ~cfg in
  Bcs.Bcs_broker.as_broker rest

let cmd_serve args =
  let port =
    match arg_value "--port" args with
    | Some v -> int_of_string v
    | None -> 8080
  in
  let live = arg_flag "--live" args in
  let broker_id =
    match arg_value "--broker" args with
    | Some v -> v
    | None -> "finam"
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
  Eio_main.run @@ fun env ->
  (* Seed mirage-crypto-rng so TLS can do handshakes. Required by
     tls-eio: without a seeded RNG every HTTPS client call blows up
     with "default generator is not yet initialized". One call at
     startup is enough — internally this installs a periodic
     getrandom(2) reseeder. *)
  Mirage_crypto_rng_unix.use_default ();
  let source =
    if not live then Server.Http.Synthetic
    else
      match secret with
      | None ->
        Server.Log.warn
          "--live requested but no secret (use --secret or %s_SECRET). \
           Falling back to synthetic." prefix;
        Server.Http.Synthetic
      | Some secret ->
        let client = match broker_id with
          | "finam" -> open_finam ~env ~secret ~account
          | "bcs"   -> open_bcs ~env ~secret ~account
          | other ->
            failwith ("unknown --broker: " ^ other ^ " (expected finam|bcs)")
        in
        Server.Log.info "live %s mode (account=%s)"
          (Broker.name client) (Option.value account ~default:"<none>");
        Server.Http.Live client
  in
  Server.Log.info "listening on http://127.0.0.1:%d (%s)"
    port (match source with
      | Synthetic -> "synthetic"
      | Live c -> "live:" ^ Broker.name c);
  Server.Http.run ~env ~port ~source

let () =
  match Array.to_list Sys.argv with
  | _ :: "list" :: _ -> cmd_list ()
  | _ :: "backtest" :: rest -> cmd_backtest rest
  | _ :: "serve" :: rest -> cmd_serve rest
  | _ -> usage ()

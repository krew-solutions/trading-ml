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

  serve [--port 8080] [--broker synthetic|finam|bcs]
        [--secret SECRET] [--account ACCOUNT_ID]
      start HTTP API server (bound to localhost).
      --broker selects the data source (default: synthetic).
      Live brokers require a secret via --secret or the matching
      <BROKER>_SECRET env var (FINAM_SECRET, BCS_SECRET); account
      likewise via --account or <BROKER>_ACCOUNT_ID. Synthetic
      ignores credentials and serves a deterministic random-walk
      through the same Broker.S port.

  list
      show registered indicators and strategies

  backtest <strategy> [--n N] [--symbol SBER@MISX]
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
    let syn = Synthetic.Synthetic_broker.make () in
    let candles = Synthetic.Synthetic_broker.bars syn
      ~n ~instrument ~timeframe:Timeframe.H1 in
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

(** Selects the secret / account env-var prefix per broker. Keeps the
    CLI single-flagged while letting users park credentials for
    multiple brokers side by side. *)
let broker_env_prefix = function
  | "bcs" -> "BCS"
  | _ -> "FINAM"

(** Opened broker: always gives back a {!Broker.client}, and for
    live brokers also the concrete REST handle so we can wire a
    {!Server.Http.live_setup} with WS feed. Synthetic has no live
    setup — polling through the adapter is enough. *)
type opened =
  | Opened_finam    of { client : Broker.client; rest : Finam.Rest.t }
  | Opened_bcs      of { client : Broker.client; rest : Bcs.Rest.t }
  | Opened_synthetic of { client : Broker.client }

let open_finam ~env ~secret ~account : opened =
  let cfg = Finam.Config.make ?account_id:account ~secret () in
  let transport = Http_transport.make_eio ~env in
  let rest = Finam.Rest.make ~transport ~cfg in
  Opened_finam { client = Finam.Finam_broker.as_broker rest; rest }

let open_bcs ~env ~secret ~account : opened =
  let cfg = Bcs.Config.make ?account_id:account ~refresh_token:secret () in
  let transport = Http_transport.make_eio ~env in
  let rest = Bcs.Rest.make ~transport ~cfg in
  Opened_bcs { client = Bcs.Bcs_broker.as_broker rest; rest }

let open_synthetic () : opened =
  let t = Synthetic.Synthetic_broker.make () in
  Opened_synthetic { client = Synthetic.Synthetic_broker.as_broker t }

let opened_client = function
  | Opened_finam    { client; _ }
  | Opened_bcs      { client; _ }
  | Opened_synthetic { client } -> client

(** Build a {!Server.Http.live_setup} that bridges Finam's WebSocket
    feed into the SSE stream registry. Connection happens up-front on
    the server's switch; per-key SUBSCRIBE/UNSUBSCRIBE messages flow
    on subscriber lifecycle hooks; inbound BARS events fan out via
    [Stream.push_from_upstream]. *)
let finam_live_setup ~env (rest : Finam.Rest.t) ~sw : Server.Http.live_setup =
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
      (match !registry_ref, timeframe with
       | Some r, Some tf ->
         List.iter (fun candle ->
           Server.Stream.push_from_upstream r
             ~instrument ~timeframe:tf candle
         ) bars
       | Some _, None ->
         (* No subscription_key in the frame — fall back to the
            legacy scan of active subs for this instrument. *)
         (match !bridge_ref with
          | None -> ()
          | Some b ->
            let tfs =
              Finam.Ws_bridge.timeframes_for_instrument b instrument in
            match !registry_ref with
            | None -> ()
            | Some r ->
              List.iter (fun candle ->
                List.iter (fun tf ->
                  Server.Stream.push_from_upstream r
                    ~instrument ~timeframe:tf candle
                ) tfs
              ) bars)
       | None, _ -> ())
    | Error_ev { code; type_; message } ->
      Server.Log.warn "[finam ws] error %d %s: %s" code type_ message
    | Lifecycle { event; code; reason } ->
      Server.Log.info "[finam ws] %s (%d) %s" event code reason
    | _ -> ()
  in
  let bridge = Finam.Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event in
  bridge_ref := Some bridge;
  Server.Http.{
    on_first = (fun ~instrument ~timeframe ->
      try Finam.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
      with e ->
        Server.Log.warn "[finam ws] subscribe failed: %s"
          (Printexc.to_string e));
    on_last = (fun ~instrument ~timeframe ->
      try Finam.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
      with e ->
        Server.Log.warn "[finam ws] unsubscribe failed: %s"
          (Printexc.to_string e));
    bind = (fun r -> registry_ref := Some r);
  }

(** Build a {!Server.Http.live_setup} for BCS. Unlike Finam, BCS
    opens one socket per subscription, so the bridge defers connect
    to [on_first] and tears down on [on_last]. The BARS fan-out
    callback pushes directly into the registry via
    [Stream.push_from_upstream]. *)
let bcs_live_setup ~env (rest : Bcs.Rest.t) ~sw : Server.Http.live_setup =
  let cfg = Bcs.Rest.cfg rest in
  let auth = Bcs.Rest.auth rest in
  let bridge = Bcs.Ws_bridge.make ~env ~sw ~cfg ~auth in
  let registry_ref : Server.Stream.t option ref = ref None in
  let push instrument timeframe candle =
    match !registry_ref with
    | Some r -> Server.Stream.push_from_upstream r ~instrument ~timeframe candle
    | None -> ()
  in
  Server.Http.{
    on_first = (fun ~instrument ~timeframe ->
      try Bcs.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
            ~on_candle:push
      with e ->
        Server.Log.warn "[bcs ws] subscribe failed: %s"
          (Printexc.to_string e));
    on_last = (fun ~instrument ~timeframe ->
      try Bcs.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
      with e ->
        Server.Log.warn "[bcs ws] unsubscribe failed: %s"
          (Printexc.to_string e));
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
  Eio_main.run @@ fun env ->
  (* Seed mirage-crypto-rng so TLS can do handshakes. Required by
     tls-eio: without a seeded RNG every HTTPS client call blows up
     with "default generator is not yet initialized". One call at
     startup is enough — internally this installs a periodic
     getrandom(2) reseeder. *)
  Mirage_crypto_rng_unix.use_default ();
  let need_secret () = match secret with
    | Some s -> s
    | None ->
      Printf.eprintf
        "--broker %s requires a secret (use --secret or %s_SECRET)\n"
        broker_id prefix;
      exit 2
  in
  let opened = match broker_id with
    | "synthetic" -> open_synthetic ()
    | "finam" -> open_finam ~env ~secret:(need_secret ()) ~account
    | "bcs"   -> open_bcs   ~env ~secret:(need_secret ()) ~account
    | other ->
      failwith ("unknown --broker: " ^ other
                ^ " (expected synthetic|finam|bcs)")
  in
  let client = opened_client opened in
  Server.Log.info "broker: %s (account=%s)"
    (Broker.name client) (Option.value account ~default:"<none>");
  let ws_setup = match opened with
    | Opened_finam     { rest; _ } -> Some (finam_live_setup ~env rest)
    | Opened_bcs       { rest; _ } -> Some (bcs_live_setup   ~env rest)
    | Opened_synthetic _           -> None
  in
  Server.Log.info "listening on http://127.0.0.1:%d (%s)"
    port (Broker.name client);
  Server.Http.run ?setup:ws_setup ~env ~port ~client ()

let () =
  match Array.to_list Sys.argv with
  | _ :: "list" :: _ -> cmd_list ()
  | _ :: "backtest" :: rest -> cmd_backtest rest
  | _ :: "serve" :: rest -> cmd_serve rest
  | _ -> usage ()

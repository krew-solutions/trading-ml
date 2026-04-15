(** CLI entry point.
    Subcommands:
      trading serve [--port 8080] [--live]
                    [--token TOKEN] [--account ACCOUNT_ID]
        start HTTP API server.
        --live  switches from synthetic data to real Finam REST.
                token / account_id come from the flags or from the
                FINAM_TOKEN / FINAM_ACCOUNT_ID environment variables.

      trading list
        show registered indicators and strategies.

      trading backtest <strategy> [--n N] [--symbol SBER]
        run a backtest on synthetic data and print summary. *)

open Core

let usage () =
  prerr_endline {|trading <command> [options]

  serve [--port 8080] [--live] [--token TOKEN] [--account ACCOUNT_ID]
      start HTTP API server (bound to localhost).
      Default mode is synthetic. Pass --live to use the real Finam REST.
      Token / account may also come from FINAM_TOKEN / FINAM_ACCOUNT_ID.

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
  let symbol =
    let rec find = function
      | "--symbol" :: v :: _ -> Symbol.of_string v
      | _ :: rest -> find rest
      | [] -> Symbol.of_string "SBER"
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
    let r = Engine.Backtest.run ~config:cfg ~strategy:strat ~symbol ~candles in
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

let cmd_serve args =
  let port =
    match arg_value "--port" args with
    | Some v -> int_of_string v
    | None -> 8080
  in
  let live = arg_flag "--live" args in
  let token =
    match arg_value "--token" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt "FINAM_TOKEN"
  in
  let account =
    match arg_value "--account" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt "FINAM_ACCOUNT_ID"
  in
  Eio_main.run @@ fun env ->
  let source =
    if not live then Server.Http.Synthetic
    else
      match token with
      | None ->
        Printf.eprintf
          "warning: --live requested but no token (use --token or \
           FINAM_TOKEN). Falling back to synthetic.\n%!";
        Server.Http.Synthetic
      | Some access_token ->
        let cfg = Finam.Config.make ?account_id:account ~access_token () in
        let transport = Finam.Eio_transport.make ~env in
        let client = Finam.Rest.make ~transport ~cfg in
        Printf.printf "trading: live Finam mode (account=%s)\n%!"
          (Option.value account ~default:"<none>");
        Server.Http.Live client
  in
  Printf.printf "trading: listening on http://127.0.0.1:%d (%s)\n%!"
    port (match source with Synthetic -> "synthetic" | Live _ -> "live");
  Server.Http.run ~env ~port ~source

let () =
  match Array.to_list Sys.argv with
  | _ :: "list" :: _ -> cmd_list ()
  | _ :: "backtest" :: rest -> cmd_backtest rest
  | _ :: "serve" :: rest -> cmd_serve rest
  | _ -> usage ()

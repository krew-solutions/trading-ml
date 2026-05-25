module T = Trading_config

let write_tmp content =
  let path = Filename.temp_file "trading_config_test" ".json" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path

let test_load_default_only () =
  let path =
    write_tmp
      {|{ "broker": "Synthetic",
          "server": {"host":"127.0.0.1","port":8080},
          "logging":{"level":"Info"} }|}
  in
  let cfg = Trading_config.Loader.load ~default_path:path () in
  let server = Option.get cfg.T.server in
  Alcotest.(check string) "host" "127.0.0.1" (Option.get server.host);
  Alcotest.(check int) "port" 8080 (Option.get server.port);
  match cfg.broker with
  | Some `Synthetic -> ()
  | _ -> Alcotest.fail "expected Synthetic"

let test_local_overrides_default () =
  let default =
    write_tmp
      {|{ "broker": "Synthetic",
          "server": {"host":"127.0.0.1","port":8080} }|}
  in
  let local = write_tmp {|{ "server": {"port":9090} }|} in
  let cfg = Trading_config.Loader.load ~default_path:default ~local_path:local () in
  let server = Option.get cfg.T.server in
  Alcotest.(check string) "host kept from default" "127.0.0.1" (Option.get server.host);
  Alcotest.(check int) "port overridden" 9090 (Option.get server.port)

let test_missing_local_is_non_fatal () =
  let default = write_tmp {|{ "server": {"port":8080} }|} in
  let cfg =
    Trading_config.Loader.load ~default_path:default ~local_path:"/non/existent/path.json"
      ()
  in
  let server = Option.get cfg.T.server in
  Alcotest.(check int) "default still applies" 8080 (Option.get server.port)

let test_env_overrides_local () =
  let default =
    write_tmp
      {|{ "broker": ["Finam", {"account_id":"DEFAULT_ACC","secret":"DEFAULT_SECRET"}] }|}
  in
  Unix.putenv "FINAM_SECRET" "FROM_ENV";
  let cfg = Trading_config.Loader.load ~default_path:default () in
  Unix.putenv "FINAM_SECRET" "";
  match cfg.broker with
  | Some (`Finam creds) ->
      Alcotest.(check string) "secret from env" "FROM_ENV" (Option.get creds.secret);
      Alcotest.(check string)
        "account_id from default" "DEFAULT_ACC" (Option.get creds.account_id)
  | _ -> Alcotest.fail "expected Finam"

let test_cli_overrides_env () =
  let default = write_tmp {|{ "server": {"host":"127.0.0.1","port":8080} }|} in
  let cli : T.t =
    {
      broker = None;
      server = Some { host = None; port = Some 7777 };
      engine = None;
      watchlist = None;
      logging = None;
    }
  in
  let cfg = Trading_config.Loader.load ~default_path:default ~cli_overrides:cli () in
  let server = Option.get cfg.T.server in
  Alcotest.(check int) "cli overrides default" 7777 (Option.get server.port);
  Alcotest.(check string) "host kept from default" "127.0.0.1" (Option.get server.host)

let test_log_level_env_override () =
  let default = write_tmp {|{ "logging": {"level":"Info"} }|} in
  Unix.putenv "LOG_LEVEL" "warning";
  let cfg = Trading_config.Loader.load ~default_path:default () in
  Unix.putenv "LOG_LEVEL" "";
  let logging = Option.get cfg.T.logging in
  match Option.get logging.level with
  | `Warning -> ()
  | _ -> Alcotest.fail "expected Warning"

(* Regression (ADR 0031): a broker named on the CLI must still receive
   its credentials from the environment. The CLI overlay carries the
   variant with empty credential fields; env fills them. *)
let test_cli_selected_broker_gets_env_creds () =
  let default = write_tmp {|{ "broker": "Synthetic" }|} in
  Unix.putenv "FINAM_ACCOUNT_ID" "ENV_ACC";
  Unix.putenv "FINAM_SECRET" "ENV_SECRET";
  let cli : T.t =
    {
      broker = Some (`Finam { account_id = None; secret = None });
      server = None;
      engine = None;
      watchlist = None;
      logging = None;
    }
  in
  let cfg = Trading_config.Loader.load ~default_path:default ~cli_overrides:cli () in
  Unix.putenv "FINAM_ACCOUNT_ID" "";
  Unix.putenv "FINAM_SECRET" "";
  match cfg.broker with
  | Some (`Finam creds) ->
      Alcotest.(check string) "account from env" "ENV_ACC" (Option.get creds.account_id);
      Alcotest.(check string) "secret from env" "ENV_SECRET" (Option.get creds.secret)
  | _ -> Alcotest.fail "expected Finam selected on the CLI"

(* CLI flag beats the env var for the same credential field. *)
let test_cli_account_overrides_env () =
  let default = write_tmp {|{ "broker": "Synthetic" }|} in
  Unix.putenv "FINAM_ACCOUNT_ID" "ENV_ACC";
  let cli : T.t =
    {
      broker = Some (`Finam { account_id = Some "CLI_ACC"; secret = Some "CLI_SECRET" });
      server = None;
      engine = None;
      watchlist = None;
      logging = None;
    }
  in
  let cfg = Trading_config.Loader.load ~default_path:default ~cli_overrides:cli () in
  Unix.putenv "FINAM_ACCOUNT_ID" "";
  match cfg.broker with
  | Some (`Finam creds) ->
      Alcotest.(check string)
        "CLI account beats env" "CLI_ACC" (Option.get creds.account_id)
  | _ -> Alcotest.fail "expected Finam"

(* Alor credentials resolve from ALOR_PORTFOLIO / ALOR_SECRET. *)
let test_alor_env_creds () =
  let default = write_tmp {|{ "broker": "Synthetic" }|} in
  Unix.putenv "ALOR_PORTFOLIO" "D777";
  Unix.putenv "ALOR_SECRET" "REFRESH";
  let cli : T.t =
    {
      broker = Some (`Alor { portfolio = None; secret = None; exchange = None });
      server = None;
      engine = None;
      watchlist = None;
      logging = None;
    }
  in
  let cfg = Trading_config.Loader.load ~default_path:default ~cli_overrides:cli () in
  Unix.putenv "ALOR_PORTFOLIO" "";
  Unix.putenv "ALOR_SECRET" "";
  match cfg.broker with
  | Some (`Alor creds) ->
      Alcotest.(check string) "portfolio from env" "D777" (Option.get creds.portfolio);
      Alcotest.(check string) "secret from env" "REFRESH" (Option.get creds.secret)
  | _ -> Alcotest.fail "expected Alor selected on the CLI"

let () =
  Alcotest.run "trading-config"
    [
      ( "loader",
        [
          Alcotest.test_case "load default only" `Quick test_load_default_only;
          Alcotest.test_case "local overrides default" `Quick test_local_overrides_default;
          Alcotest.test_case "missing local is non-fatal" `Quick
            test_missing_local_is_non_fatal;
          Alcotest.test_case "env overrides local on credentials" `Quick
            test_env_overrides_local;
          Alcotest.test_case "cli overrides default" `Quick test_cli_overrides_env;
          Alcotest.test_case "LOG_LEVEL env overrides logging" `Quick
            test_log_level_env_override;
          Alcotest.test_case "CLI-selected broker gets env credentials" `Quick
            test_cli_selected_broker_gets_env_creds;
          Alcotest.test_case "CLI flag overrides env credential" `Quick
            test_cli_account_overrides_env;
          Alcotest.test_case "Alor credentials from env" `Quick test_alor_env_creds;
        ] );
    ]

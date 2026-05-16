(** Sociable tests for {!Paper_broker_commands.Submit_order_command_workflow}.
    Drives the real domain, real handler, real DEH; only the
    {!Paper_broker_store.Order_store.S} and
    {!Paper_broker_store.Order_command_log.S} adapters and the bus
    publish closures are stand-ins. *)

module Submit = Paper_broker_commands.Submit_order_command
module Workflow = Paper_broker_commands.Submit_order_command_workflow

let store_module =
  (module Test_store : Paper_broker_store.Order_store.S with type t = Test_store.t)

let log_module =
  (module Test_command_log : Paper_broker_store.Order_command_log.S
    with type t = Test_command_log.t)

let next_id_seq () =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "po-%d" !n

let market_cmd
    ?(correlation_id = "saga-1")
    ?(placement_id = 7)
    ?(symbol = "SBER@MISX")
    ?(side = "BUY")
    ?(quantity = "10")
    ?(tif = "GTC")
    () : Submit.t =
  {
    correlation_id;
    placement_id;
    symbol;
    side;
    quantity;
    kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
    tif;
  }

let test_happy_path_publishes_order_accepted () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let next_id = next_id_seq () in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:next_id
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      (market_cmd ())
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  Alcotest.(check int) "store size = 1" 1 (Test_store.length store);
  Alcotest.(check int) "no rejection" 0 (List.length !rejected);
  Alcotest.(check (option string))
    "submit correlation recorded in log" (Some "saga-1")
    (Test_command_log.origin_correlation_id log ~aggregate_id:"po-1");
  match !accepted with
  | [ ie ] ->
      Alcotest.(check string) "correlation_id" "saga-1" ie.correlation_id;
      Alcotest.(check int) "placement_id" 7 ie.placement_id
  | _ -> Alcotest.fail "expected exactly one Order_accepted IE"

let test_invalid_side_publishes_rejection () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      (market_cmd ~side:"NEITHER" ())
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no Order_accepted" 0 (List.length !accepted);
  Alcotest.(check int) "store still empty" 0 (Test_store.length store);
  match !rejected with
  | [ ie ] ->
      Alcotest.(check string) "correlation_id" "saga-1" ie.correlation_id;
      Alcotest.(check int) "placement_id" 7 ie.placement_id;
      let contains_substring s sub =
        let ls = String.length s and lsub = String.length sub in
        let rec loop i =
          if i + lsub > ls then false
          else if String.sub s i lsub = sub then true
          else loop (i + 1)
        in
        loop 0
      in
      Alcotest.(check bool)
        "reason mentions side" true
        (contains_substring ie.reason "side")
  | _ -> Alcotest.fail "expected exactly one Order_rejected IE"

let test_limit_order_requires_price () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let cmd : Submit.t =
    {
      (market_cmd ()) with
      kind = { type_ = "LIMIT"; price = None; stop_price = None; limit_price = None };
    }
  in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      cmd
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no Order_accepted" 0 (List.length !accepted);
  Alcotest.(check int) "one Order_rejected" 1 (List.length !rejected)

let test_sell_happy_path_publishes_order_accepted () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      (market_cmd ~side:"SELL" ())
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  Alcotest.(check int) "store size = 1" 1 (Test_store.length store);
  Alcotest.(check int) "no rejection" 0 (List.length !rejected);
  match !accepted with
  | [ ie ] -> Alcotest.(check int) "placement_id" 7 ie.placement_id
  | _ -> Alcotest.fail "expected exactly one Order_accepted IE"

let test_limit_sell_without_price_is_rejected () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let cmd : Submit.t =
    {
      (market_cmd ~side:"SELL" ()) with
      kind = { type_ = "LIMIT"; price = None; stop_price = None; limit_price = None };
    }
  in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      cmd
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no Order_accepted" 0 (List.length !accepted);
  match !rejected with
  | [ ie ] -> Alcotest.(check int) "placement_id echoed on rejection" 7 ie.placement_id
  | _ -> Alcotest.fail "expected exactly one Order_rejected IE"

let test_non_positive_placement_id_is_rejected () =
  let store = Test_store.create () in
  let log = Test_command_log.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~command_log:log_module
      ~command_log_handle:log ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      (market_cmd ~placement_id:0 ())
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no Order_accepted" 0 (List.length !accepted);
  Alcotest.(check int) "one Order_rejected" 1 (List.length !rejected)

let tests =
  [
    ( "happy path publishes Order_accepted and records origin correlation",
      `Quick,
      test_happy_path_publishes_order_accepted );
    ( "invalid side publishes Order_rejected",
      `Quick,
      test_invalid_side_publishes_rejection );
    ( "LIMIT without price publishes Order_rejected",
      `Quick,
      test_limit_order_requires_price );
    ( "SELL happy path publishes Order_accepted",
      `Quick,
      test_sell_happy_path_publishes_order_accepted );
    ( "LIMIT SELL without price is rejected and echoes placement_id",
      `Quick,
      test_limit_sell_without_price_is_rejected );
    ( "placement_id <= 0 is rejected at validation",
      `Quick,
      test_non_positive_placement_id_is_rejected );
  ]

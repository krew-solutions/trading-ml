(** Sociable tests for {!Paper_broker_commands.Submit_order_command_workflow}.
    Drives the real domain, real handler, real DEH; only the
    {!Order_store.S} adapter and the bus publish closures are
    stand-ins. *)

module Submit = Paper_broker_commands.Submit_order_command
module Workflow = Paper_broker_commands.Submit_order_command_workflow

let store_module =
  (module Test_store : Paper_broker_commands.Order_store.S with type t = Test_store.t)

let next_id_seq () =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "po-%d" !n

let market_cmd
    ?(correlation_id = "saga-1")
    ?(reservation_id = 7)
    ?(symbol = "SBER@MISX")
    ?(side = "BUY")
    ?(quantity = "10")
    ?(tif = "GTC")
    () : Submit.t =
  {
    correlation_id;
    reservation_id;
    symbol;
    side;
    quantity;
    kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
    tif;
  }

let test_happy_path_publishes_order_accepted () =
  let store = Test_store.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let next_id = next_id_seq () in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store ~next_order_id:next_id
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      (market_cmd ())
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  Alcotest.(check int) "store size = 1" 1 (Test_store.length store);
  Alcotest.(check int) "no rejection" 0 (List.length !rejected);
  match !accepted with
  | [ ie ] ->
      Alcotest.(check string) "correlation_id" "saga-1" ie.correlation_id;
      Alcotest.(check int) "reservation_id" 7 ie.reservation_id;
      Alcotest.(check string) "id" "po-1" ie.id;
      Alcotest.(check string) "side" "BUY" ie.side;
      Alcotest.(check string) "quantity" "10" ie.quantity;
      Alcotest.(check string) "instrument ticker" "SBER" ie.instrument.ticker;
      Alcotest.(check string) "instrument venue" "MISX" ie.instrument.venue
  | _ -> Alcotest.fail "expected exactly one Order_accepted IE"

let test_invalid_side_publishes_rejection () =
  let store = Test_store.create () in
  let accepted = ref [] in
  let rejected = ref [] in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store
      ~next_order_id:(next_id_seq ())
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
      Alcotest.(check int) "reservation_id" 7 ie.reservation_id;
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
  let accepted = ref [] in
  let rejected = ref [] in
  let cmd : Submit.t =
    {
      (market_cmd ()) with
      kind = { type_ = "LIMIT"; price = None; stop_price = None; limit_price = None };
    }
  in
  let result =
    Workflow.execute ~store:store_module ~store_handle:store
      ~next_order_id:(next_id_seq ())
      ~now_ts:(fun () -> 1_700_000_010L)
      ~placed_after_ts:(fun _ -> 1_700_000_000L)
      ~publish_order_accepted:(fun ie -> accepted := ie :: !accepted)
      ~publish_order_rejected:(fun ie -> rejected := ie :: !rejected)
      cmd
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no Order_accepted" 0 (List.length !accepted);
  Alcotest.(check int) "one Order_rejected" 1 (List.length !rejected)

let tests =
  [
    ( "happy path publishes Order_accepted",
      `Quick,
      test_happy_path_publishes_order_accepted );
    ( "invalid side publishes Order_rejected",
      `Quick,
      test_invalid_side_publishes_rejection );
    ( "LIMIT without price publishes Order_rejected",
      `Quick,
      test_limit_order_requires_price );
  ]

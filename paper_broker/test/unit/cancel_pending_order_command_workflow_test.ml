(** Sociable tests for {!Paper_broker_commands.Cancel_pending_order_command_workflow}. *)

module Submit = Paper_broker_commands.Submit_order_command
module Submit_wf = Paper_broker_commands.Submit_order_command_workflow
module Cancel = Paper_broker_commands.Cancel_pending_order_command
module Cancel_wf = Paper_broker_commands.Cancel_pending_order_command_workflow
module Cancel_handler = Paper_broker_commands.Cancel_pending_order_command_handler

let store_module =
  (module Test_store : Paper_broker_commands.Order_store.S with type t = Test_store.t)

let make_id_seq prefix =
  let n = ref 0 in
  fun () ->
    incr n;
    Printf.sprintf "%s-%d" prefix !n

let submit_market_buy
    ~store
    ~next_id
    ~now_ts
    ~placed_after_ts
    ~correlation_id
    ~reservation_id =
  let cmd : Submit.t =
    {
      correlation_id;
      reservation_id;
      symbol = "SBER@MISX";
      side = "BUY";
      quantity = "10";
      kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
      tif = "GTC";
    }
  in
  let _ =
    Submit_wf.execute ~store:store_module ~store_handle:store ~next_order_id:next_id
      ~now_ts ~placed_after_ts
      ~publish_order_accepted:(fun _ -> ())
      ~publish_order_rejected:(fun _ -> ())
      cmd
  in
  ()

let test_cancel_working_order_publishes_ie () =
  let store = Test_store.create () in
  let next_id = make_id_seq "po" in
  submit_market_buy ~store ~next_id
    ~now_ts:(fun () -> 1_700_000_000L)
    ~placed_after_ts:(fun _ -> 1_700_000_000L)
    ~correlation_id:"saga-A" ~reservation_id:42;
  let cancelled = ref [] in
  let result =
    Cancel_wf.execute ~store:store_module ~store_handle:store
      ~now_ts:(fun () -> 1_700_000_100L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "cancel-A"; id = "po-1" }
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  match !cancelled with
  | [ ie ] ->
      Alcotest.(check string)
        "correlation_id from cancel cmd" "cancel-A" ie.correlation_id;
      Alcotest.(check int) "reservation_id from pending" 42 ie.reservation_id;
      Alcotest.(check string) "id" "po-1" ie.id
  | _ -> Alcotest.fail "expected exactly one Order_cancelled IE"

let test_cancel_unknown_order_returns_not_found () =
  let store = Test_store.create () in
  let cancelled = ref [] in
  let result =
    Cancel_wf.execute ~store:store_module ~store_handle:store
      ~now_ts:(fun () -> 1_700_000_100L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "x"; id = "po-DOES-NOT-EXIST" }
  in
  Alcotest.(check int) "no IE emitted" 0 (List.length !cancelled);
  match result with
  | Error [ Cancel_handler.Cancel (Order_not_found _) ] -> ()
  | _ -> Alcotest.fail "expected Order_not_found"

let tests =
  [
    ( "cancel working order publishes Order_cancelled IE",
      `Quick,
      test_cancel_working_order_publishes_ie );
    ( "cancel unknown id yields Order_not_found",
      `Quick,
      test_cancel_unknown_order_returns_not_found );
  ]

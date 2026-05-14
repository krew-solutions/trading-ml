(** Sociable tests for {!Paper_broker_commands.Apply_bar_command_workflow}.
    Submits an order via the real submit pipeline, then drives the
    bar through {!Apply_bar_command_workflow.execute} and observes
    the resulting {!Order_filled_integration_event}. *)

module Submit = Paper_broker_commands.Submit_order_command
module Submit_wf = Paper_broker_commands.Submit_order_command_workflow
module Apply_bar = Paper_broker_commands.Apply_bar_command
module Apply_bar_wf = Paper_broker_commands.Apply_bar_command_workflow
module Slippage_bps = Paper_broker.Slippage.Values.Slippage_bps
module Fee_rate = Paper_broker.Fee.Values.Fee_rate

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
    ~reservation_id
    ~quantity =
  let cmd : Submit.t =
    {
      correlation_id;
      reservation_id;
      symbol = "SBER@MISX";
      side = "BUY";
      quantity;
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

let bar_cmd
    ?(ts = "2024-01-01T10:00:00Z")
    ?(open_ = "100")
    ?(high = "105")
    ?(low = "95")
    ?(close = "102")
    ?(volume = "1000")
    () : Apply_bar.t =
  {
    instrument = "SBER@MISX";
    timeframe = "1m";
    candle = { ts; open_; high; low; close; volume };
  }

let test_bar_fills_market_buy_at_open () =
  let store = Test_store.create () in
  let next_order_id = make_id_seq "po" in
  let next_exec_id = make_id_seq "ex" in
  submit_market_buy ~store ~next_id:next_order_id
    ~now_ts:(fun () -> 1_700_000_000L)
    ~placed_after_ts:(fun _ -> 1_700_000_000L)
    ~correlation_id:"saga-A" ~reservation_id:101 ~quantity:"10";
  let filled = ref [] in
  let result =
    Apply_bar_wf.execute ~store:store_module ~store_handle:store
      ~slippage_bps:Slippage_bps.zero ~fee_rate:Fee_rate.zero ~next_exec_id
      ~publish_order_filled:(fun ie -> filled := ie :: !filled)
      (bar_cmd ())
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  match !filled with
  | [ ie ] ->
      Alcotest.(check string) "correlation_id" "saga-A" ie.correlation_id;
      Alcotest.(check int) "reservation_id" 101 ie.reservation_id;
      Alcotest.(check string) "fill price = open" "100" ie.fill_price;
      Alcotest.(check string) "fill quantity = remaining" "10" ie.fill_quantity;
      Alcotest.(check string) "new_total_filled" "10" ie.new_total_filled
  | _ -> Alcotest.fail "expected exactly one Order_filled IE"

let test_bar_at_placed_after_ts_does_not_fill () =
  let store = Test_store.create () in
  let next_order_id = make_id_seq "po" in
  let next_exec_id = make_id_seq "ex" in
  (* placed_after_ts equals the bar ts → no-lookahead rule prevents fill. *)
  let bar_ts_int64 = Datetime.Iso8601.parse "2024-01-01T10:00:00Z" in
  submit_market_buy ~store ~next_id:next_order_id
    ~now_ts:(fun () -> bar_ts_int64)
    ~placed_after_ts:(fun _ -> bar_ts_int64)
    ~correlation_id:"saga-B" ~reservation_id:202 ~quantity:"10";
  let filled = ref [] in
  let _ =
    Apply_bar_wf.execute ~store:store_module ~store_handle:store
      ~slippage_bps:Slippage_bps.zero ~fee_rate:Fee_rate.zero ~next_exec_id
      ~publish_order_filled:(fun ie -> filled := ie :: !filled)
      (bar_cmd ())
  in
  Alcotest.(check int) "no fills on same-ts bar" 0 (List.length !filled);
  Alcotest.(check int) "order still tracked" 1 (Test_store.length store)

let test_bar_for_different_instrument_does_not_fill () =
  let store = Test_store.create () in
  let next_order_id = make_id_seq "po" in
  let next_exec_id = make_id_seq "ex" in
  submit_market_buy ~store ~next_id:next_order_id
    ~now_ts:(fun () -> 1_700_000_000L)
    ~placed_after_ts:(fun _ -> 1_700_000_000L)
    ~correlation_id:"saga-C" ~reservation_id:303 ~quantity:"10";
  let filled = ref [] in
  let other_bar : Apply_bar.t = { (bar_cmd ()) with instrument = "GAZP@MISX" } in
  let _ =
    Apply_bar_wf.execute ~store:store_module ~store_handle:store
      ~slippage_bps:Slippage_bps.zero ~fee_rate:Fee_rate.zero ~next_exec_id
      ~publish_order_filled:(fun ie -> filled := ie :: !filled)
      other_bar
  in
  Alcotest.(check int) "no cross-instrument fill" 0 (List.length !filled)

let test_invalid_bar_returns_error () =
  let store = Test_store.create () in
  let next_exec_id = make_id_seq "ex" in
  let filled = ref [] in
  let bad : Apply_bar.t = { (bar_cmd ()) with instrument = "GARBAGE" } in
  let result =
    Apply_bar_wf.execute ~store:store_module ~store_handle:store
      ~slippage_bps:Slippage_bps.zero ~fee_rate:Fee_rate.zero ~next_exec_id
      ~publish_order_filled:(fun ie -> filled := ie :: !filled)
      bad
  in
  Alcotest.(check bool) "workflow Error" true (Result.is_error result);
  Alcotest.(check int) "no fill emitted" 0 (List.length !filled)

let tests =
  [
    ("bar fills market buy at open", `Quick, test_bar_fills_market_buy_at_open);
    ( "no-lookahead: bar with ts == placed_after_ts does not fill",
      `Quick,
      test_bar_at_placed_after_ts_does_not_fill );
    ( "different-instrument bar does not fill",
      `Quick,
      test_bar_for_different_instrument_does_not_fill );
    ("invalid bar instrument returns Error", `Quick, test_invalid_bar_returns_error);
  ]

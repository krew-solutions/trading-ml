(** Unit tests for {!Execution_management.Kill_switch}. *)

let d = Decimal.of_string

let pct f = Execution_management.Kill_switch.Values.Max_drawdown_pct.of_float f

let test_disabled_never_trips () =
  let ks =
    Execution_management.Kill_switch.make ~initial_equity:(d "1000")
      ~max_drawdown_pct:(pct 0.0)
  in
  let _, ev =
    Execution_management.Kill_switch.update_equity ks ~equity:(d "1") ~occurred_at:0L
  in
  Alcotest.(check bool) "no trip" true (Option.is_none ev)

let test_within_threshold_does_not_trip () =
  let ks =
    Execution_management.Kill_switch.make ~initial_equity:(d "1000")
      ~max_drawdown_pct:(pct 0.2)
  in
  let ks', ev =
    Execution_management.Kill_switch.update_equity ks ~equity:(d "850") ~occurred_at:0L
  in
  Alcotest.(check bool) "no trip" true (Option.is_none ev);
  Alcotest.(check bool)
    "not halted" false
    (Execution_management.Kill_switch.is_halted ks')

let test_breach_trips_once () =
  let ks =
    Execution_management.Kill_switch.make ~initial_equity:(d "1000")
      ~max_drawdown_pct:(pct 0.2)
  in
  let ks', ev =
    Execution_management.Kill_switch.update_equity ks ~equity:(d "750") ~occurred_at:0L
  in
  Alcotest.(check bool) "tripped" true (Option.is_some ev);
  Alcotest.(check bool) "halted" true (Execution_management.Kill_switch.is_halted ks');
  let _, ev2 =
    Execution_management.Kill_switch.update_equity ks' ~equity:(d "700") ~occurred_at:1L
  in
  Alcotest.(check bool) "no second trip" true (Option.is_none ev2)

let test_peak_grows_with_equity () =
  let ks =
    Execution_management.Kill_switch.make ~initial_equity:(d "1000")
      ~max_drawdown_pct:(pct 0.2)
  in
  let ks, _ =
    Execution_management.Kill_switch.update_equity ks ~equity:(d "1500") ~occurred_at:0L
  in
  Alcotest.(check string)
    "peak grew" "1500"
    (Decimal.to_string (Execution_management.Kill_switch.peak_equity ks))

let test_reset_clears_halt () =
  let ks =
    Execution_management.Kill_switch.make ~initial_equity:(d "1000")
      ~max_drawdown_pct:(pct 0.1)
  in
  let ks, _ =
    Execution_management.Kill_switch.update_equity ks ~equity:(d "850") ~occurred_at:0L
  in
  Alcotest.(check bool)
    "halted before reset" true
    (Execution_management.Kill_switch.is_halted ks);
  let ks, _ =
    Execution_management.Kill_switch.reset ks ~new_peak_equity:(d "850") ~occurred_at:1L
  in
  Alcotest.(check bool) "not halted" false (Execution_management.Kill_switch.is_halted ks);
  Alcotest.(check string)
    "peak reset" "850"
    (Decimal.to_string (Execution_management.Kill_switch.peak_equity ks))

let tests =
  [
    Alcotest.test_case "disabled never trips" `Quick test_disabled_never_trips;
    Alcotest.test_case "within threshold does not trip" `Quick
      test_within_threshold_does_not_trip;
    Alcotest.test_case "breach trips once" `Quick test_breach_trips_once;
    Alcotest.test_case "peak grows with equity" `Quick test_peak_grows_with_equity;
    Alcotest.test_case "reset clears halt" `Quick test_reset_clears_halt;
  ]

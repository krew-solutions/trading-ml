(** Unit tests for {!Pre_trade_risk.Rate_limit}. *)

let cfg ~max_orders ~window_seconds =
  Pre_trade_risk.Rate_limit.Values.Rate_limit_config.make ~max_orders ~window_seconds

let test_allows_under_cap () =
  let r =
    Pre_trade_risk.Rate_limit.make ~config:(cfg ~max_orders:3 ~window_seconds:10.0)
  in
  match Pre_trade_risk.Rate_limit.try_acquire r ~now:0.0 with
  | `Allow _ -> ()
  | `Throttle -> Alcotest.fail "expected Allow"

let test_throttles_at_cap () =
  let r =
    Pre_trade_risk.Rate_limit.make ~config:(cfg ~max_orders:2 ~window_seconds:10.0)
  in
  let r =
    match Pre_trade_risk.Rate_limit.try_acquire r ~now:0.0 with
    | `Allow r' -> r'
    | `Throttle -> Alcotest.fail "first allow"
  in
  let r =
    match Pre_trade_risk.Rate_limit.try_acquire r ~now:1.0 with
    | `Allow r' -> r'
    | `Throttle -> Alcotest.fail "second allow"
  in
  match Pre_trade_risk.Rate_limit.try_acquire r ~now:2.0 with
  | `Throttle -> ()
  | `Allow _ -> Alcotest.fail "expected Throttle"

let test_window_eviction_re_allows () =
  let r =
    Pre_trade_risk.Rate_limit.make ~config:(cfg ~max_orders:1 ~window_seconds:5.0)
  in
  let r =
    match Pre_trade_risk.Rate_limit.try_acquire r ~now:0.0 with
    | `Allow r' -> r'
    | `Throttle -> Alcotest.fail "first allow"
  in
  (* immediate retry → throttled *)
  (match Pre_trade_risk.Rate_limit.try_acquire r ~now:1.0 with
  | `Throttle -> ()
  | `Allow _ -> Alcotest.fail "should throttle while window holds");
  (* after window slides past, allow again *)
  match Pre_trade_risk.Rate_limit.try_acquire r ~now:6.0 with
  | `Allow _ -> ()
  | `Throttle -> Alcotest.fail "should allow after eviction"

let tests =
  [
    Alcotest.test_case "allows under cap" `Quick test_allows_under_cap;
    Alcotest.test_case "throttles at cap" `Quick test_throttles_at_cap;
    Alcotest.test_case "window eviction re-allows" `Quick test_window_eviction_re_allows;
  ]

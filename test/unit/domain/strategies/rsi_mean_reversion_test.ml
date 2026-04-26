open Core

open Strategy_helpers

let build
    ?(period = 14)
    ?(lower = 30.)
    ?(upper = 70.)
    ?(exit_long = 50.)
    ?(exit_short = 50.)
    ?(allow_short = false)
    () =
  let p =
    Strategies.Rsi_mean_reversion.
      { period; lower; upper; exit_long; exit_short; allow_short }
  in
  Strategies.Strategy.make (module Strategies.Rsi_mean_reversion) p

let test_oversold_enters_long () =
  (* Monotone downtrend drives RSI toward 0 — must cross below 30. *)
  let strat = build () in
  let prices = List.init 40 (fun i -> 100. -. float_of_int i) in
  let acts = actions_from_prices strat prices in
  Alcotest.(check bool)
    "enter_long fires on oversold" true
    (contains Signal.Enter_long acts)

let test_recovery_exits_long () =
  (* Downtrend (enter_long) then a recovery pushing RSI above 50. *)
  let down = List.init 40 (fun i -> 100. -. float_of_int i) in
  let up = List.init 40 (fun i -> 60. +. float_of_int i) in
  let strat = build () in
  let acts = actions_from_prices strat (down @ up) in
  Alcotest.(check bool) "enter_long fires" true (contains Signal.Enter_long acts);
  Alcotest.(check bool) "exit_long follows" true (contains Signal.Exit_long acts)

let test_overbought_shorts_when_allowed () =
  let strat = build ~allow_short:true () in
  let prices = List.init 40 (fun i -> 100. +. float_of_int i) in
  let acts = actions_from_prices strat prices in
  Alcotest.(check bool)
    "enter_short on overbought uptrend" true
    (contains Signal.Enter_short acts)

let test_overbought_silent_when_short_disabled () =
  let strat = build ~allow_short:false () in
  let prices = List.init 40 (fun i -> 100. +. float_of_int i) in
  let acts = actions_from_prices strat prices in
  Alcotest.(check bool)
    "no enter_short when disabled" true
    (not (contains Signal.Enter_short acts))

let test_rejects_bad_thresholds () =
  Alcotest.check_raises "lower >= upper" (Invalid_argument "RSI_MR: lower >= upper")
    (fun () -> ignore (build ~lower:70. ~upper:30. ()))

let tests =
  [
    ("oversold → enter_long", `Quick, test_oversold_enters_long);
    ("recovery → exit_long", `Quick, test_recovery_exits_long);
    ("overbought → enter_short (on)", `Quick, test_overbought_shorts_when_allowed);
    ("overbought silent (short off)", `Quick, test_overbought_silent_when_short_disabled);
    ("rejects lower >= upper", `Quick, test_rejects_bad_thresholds);
  ]

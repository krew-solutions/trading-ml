open Core
open Strategy_helpers

let build ?(period = 14) ?(lower = 20.) ?(upper = 80.)
          ?(exit_long = 50.) ?(exit_short = 50.)
          ?(allow_short = false) () =
  let p = Strategies.Mfi_mean_reversion.{
    period; lower; upper; exit_long; exit_short; allow_short;
  } in
  Strategies.Strategy.make (module Strategies.Mfi_mean_reversion) p

let test_oversold_enters_long () =
  let strat = build () in
  let prices = List.init 40 (fun i -> 100. -. float_of_int i) in
  let candles = ohlc_candles_from_prices prices in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_long on oversold"
    true (contains Signal.Enter_long acts)

let test_recovery_exits_long () =
  let down = List.init 30 (fun i -> 100. -. float_of_int i) in
  let up   = List.init 40 (fun i -> 70.  +. float_of_int i) in
  let strat = build () in
  let candles = ohlc_candles_from_prices (down @ up) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_long"  true (contains Signal.Enter_long acts);
  Alcotest.(check bool) "exit_long"   true (contains Signal.Exit_long acts)

let test_overbought_shorts_when_allowed () =
  let strat = build ~allow_short:true () in
  let prices = List.init 40 (fun i -> 100. +. float_of_int i) in
  let candles = ohlc_candles_from_prices prices in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_short on overbought"
    true (contains Signal.Enter_short acts)

let test_overbought_silent_when_short_disabled () =
  let strat = build ~allow_short:false () in
  let prices = List.init 40 (fun i -> 100. +. float_of_int i) in
  let candles = ohlc_candles_from_prices prices in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "no enter_short when disabled"
    true (not (contains Signal.Enter_short acts))

let test_rejects_bad_thresholds () =
  Alcotest.check_raises "lower >= upper"
    (Invalid_argument "MFI_MR: lower >= upper")
    (fun () -> ignore (build ~lower:80. ~upper:20. ()))

let tests = [
  "oversold → enter_long",          `Quick, test_oversold_enters_long;
  "recovery → exit_long",           `Quick, test_recovery_exits_long;
  "overbought → enter_short (on)",  `Quick, test_overbought_shorts_when_allowed;
  "overbought silent (short off)",  `Quick, test_overbought_silent_when_short_disabled;
  "rejects lower >= upper",         `Quick, test_rejects_bad_thresholds;
]

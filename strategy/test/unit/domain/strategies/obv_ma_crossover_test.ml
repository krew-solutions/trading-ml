open Core
open Strategy_helpers

let build ?(period = 20) ?(allow_short = false) () =
  let p = Strategies.Obv_ma_crossover.{ period; allow_short } in
  Strategies.Strategy.make (module Strategies.Obv_ma_crossover) p

let test_uptrend_triggers_enter_long () =
  (* A downtrend primes OBV negative and SMA(OBV) follows. Then an
     uptrend: OBV starts climbing; once it crosses above its lagging
     SMA, the strategy fires Enter_long. *)
  let strat = build ~period:10 () in
  let down = List.init 20 (fun i -> 100. -. float_of_int i) in
  let up = List.init 30 (fun i -> 80. +. float_of_int i) in
  let candles = ohlc_candles_from_prices (down @ up) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool)
    "enter_long on OBV/SMA cross-up" true
    (contains Signal.Enter_long acts)

let test_reversal_exits_long () =
  (* Priming downtrend sets last_diff < 0 so the subsequent uptrend
     can cross-up and fire Enter_long; then a downtrend crosses
     back and fires Exit_long. *)
  let prime = List.init 15 (fun i -> 100. -. float_of_int i) in
  let up = List.init 25 (fun i -> 85. +. float_of_int i) in
  let down = List.init 30 (fun i -> 110. -. float_of_int i) in
  let strat = build ~period:10 () in
  let candles = ohlc_candles_from_prices (prime @ up @ down) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_long" true (contains Signal.Enter_long acts);
  Alcotest.(check bool) "exit_long" true (contains Signal.Exit_long acts)

let test_short_disabled_by_default () =
  let prime = List.init 15 (fun i -> 100. -. float_of_int i) in
  let up = List.init 25 (fun i -> 85. +. float_of_int i) in
  let down = List.init 30 (fun i -> 110. -. float_of_int i) in
  let strat = build ~period:10 ~allow_short:false () in
  let candles = ohlc_candles_from_prices (prime @ up @ down) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool)
    "no enter_short when disabled" true
    (not (contains Signal.Enter_short acts))

let test_rejects_bad_period () =
  Alcotest.check_raises "period <= 0" (Invalid_argument "OBV_MA_Crossover: period > 0")
    (fun () -> ignore (build ~period:0 ()))

let tests =
  [
    ("uptrend → enter_long", `Quick, test_uptrend_triggers_enter_long);
    ("reversal → exit_long", `Quick, test_reversal_exits_long);
    ("short disabled by default", `Quick, test_short_disabled_by_default);
    ("rejects period <= 0", `Quick, test_rejects_bad_period);
  ]

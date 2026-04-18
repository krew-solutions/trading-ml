open Core
open Strategy_helpers

let build ?(fast = 3) ?(slow = 10) ?(allow_short = false) () =
  let p = Strategies.Chaikin_momentum.{ fast; slow; allow_short } in
  Strategies.Strategy.make (module Strategies.Chaikin_momentum) p

let test_regime_flip_triggers_enter_long () =
  (* Distribution phase (price falls, A/D falls) primes oscillator
     negative. Accumulation phase (price rises, A/D rises) drives the
     oscillator through zero → Enter_long. *)
  let strat = build ~fast:3 ~slow:10 () in
  let down = List.init 30 (fun i -> 100. -. float_of_int i) in
  let up   = List.init 40 (fun i -> 70.  +. float_of_int i) in
  let candles = ohlc_candles_from_prices (down @ up) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_long on zero-cross up"
    true (contains Signal.Enter_long acts)

let test_reversal_exits_long () =
  (* Priming downtrend → uptrend (Enter_long) → downtrend (Exit). *)
  let prime = List.init 20 (fun i -> 100. -. float_of_int i) in
  let up    = List.init 30 (fun i -> 80.  +. float_of_int i) in
  let down  = List.init 40 (fun i -> 110. -. float_of_int i) in
  let strat = build ~fast:3 ~slow:10 () in
  let candles = ohlc_candles_from_prices (prime @ up @ down) in
  let acts = actions_from_ohlc strat candles in
  Alcotest.(check bool) "enter_long" true (contains Signal.Enter_long acts);
  Alcotest.(check bool) "exit_long"  true (contains Signal.Exit_long acts)

let test_rejects_fast_ge_slow () =
  Alcotest.check_raises "fast >= slow"
    (Invalid_argument "Chaikin_Momentum: fast < slow")
    (fun () -> ignore (build ~fast:10 ~slow:3 ()))

let test_rejects_non_positive () =
  Alcotest.check_raises "fast <= 0"
    (Invalid_argument "Chaikin_Momentum: periods > 0")
    (fun () -> ignore (build ~fast:0 ~slow:10 ()))

let tests = [
  "regime flip → enter_long",  `Quick, test_regime_flip_triggers_enter_long;
  "reversal → exit_long",      `Quick, test_reversal_exits_long;
  "rejects fast >= slow",      `Quick, test_rejects_fast_ge_slow;
  "rejects period <= 0",       `Quick, test_rejects_non_positive;
]

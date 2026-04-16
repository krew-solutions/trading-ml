open Core

let d = Decimal.of_float

let make_candles closes =
  List.mapi (fun i c ->
    let px = Decimal.of_float c in
    Candle.make
      ~ts:(Int64.of_int (i * 60))
      ~open_:px ~high:px ~low:px ~close:px ~volume:(Decimal.of_int 1))
    closes

let test_sma_crossover_no_crash () =
  let closes =
    List.init 200 (fun i ->
      50.0 +. 10.0 *. sin (float_of_int i /. 10.0))
  in
  let candles = make_candles closes in
  let sym = Symbol.of_string "SBER" in
  let cfg = Engine.Backtest.default_config () in
  let strat = Strategies.Strategy.default (module Strategies.Sma_crossover) in
  let result = Engine.Backtest.run ~config:cfg ~strategy:strat ~symbol:sym ~candles in
  Alcotest.(check bool) "equity curve populated" true
    (List.length result.equity_curve = List.length candles);
  Alcotest.(check bool) "drawdown in [0,1]" true
    (result.max_drawdown >= 0.0 && result.max_drawdown <= 1.0)

let test_determinism () =
  let closes = List.init 100 (fun i -> 100.0 +. float_of_int (i mod 7)) in
  let candles = make_candles closes in
  let sym = Symbol.of_string "GAZP" in
  let cfg = Engine.Backtest.default_config () in
  let run1 =
    Engine.Backtest.run ~config:cfg ~symbol:sym ~candles
      ~strategy:(Strategies.Strategy.default (module Strategies.Rsi_mean_reversion))
  in
  let run2 =
    Engine.Backtest.run ~config:cfg ~symbol:sym ~candles
      ~strategy:(Strategies.Strategy.default (module Strategies.Rsi_mean_reversion))
  in
  Alcotest.(check int) "same num trades"
    run1.num_trades run2.num_trades;
  Alcotest.(check (float 1e-9)) "same return"
    run1.total_return run2.total_return

let _ = d

let tests = [
  "sma crossover runs", `Quick, test_sma_crossover_no_crash;
  "backtest deterministic", `Quick, test_determinism;
]

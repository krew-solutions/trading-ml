(** End-to-end test: train logistic regression on synthetic data,
    wire it into [Composite.Learned] via a predictor closure, and
    verify the composite produces sensible signals. *)

open Core
open Strategy_helpers

let make_predictor weights : Strategies.Composite.predictor =
 fun ~signals ~candle ~recent_closes ~recent_volumes ->
  let features =
    Logistic_regression.Features.extract ~signals ~candle ~recent_closes ~recent_volumes
  in
  let model = Logistic_regression.Logistic.of_weights weights in
  Logistic_regression.Logistic.predict model features

let children_build () =
  [
    Strategies.Strategy.default (module Strategies.Sma_crossover);
    Strategies.Strategy.default (module Strategies.Rsi_mean_reversion);
  ]

let prices = List.init 300 (fun i -> 50.0 +. (15.0 *. sin (float_of_int i /. 8.0)))

let candles =
  List.mapi
    (fun i p ->
      let px = Decimal.of_float p in
      Candle.make
        ~ts:(Int64.of_int (i * 60))
        ~open_:px ~high:px ~low:px ~close:px ~volume:(Decimal.of_int 100))
    prices

let test_learned_produces_signals () =
  let result =
    Logistic_regression.Trainer.train ~children:(children_build ()) ~candles ~lookahead:5
      ~epochs:10 ()
  in
  let predict = make_predictor result.weights in
  let strat =
    Strategies.Strategy.make
      (module Strategies.Composite)
      Strategies.Composite.
        { policy = Learned { predict; threshold = 0.6 }; children = children_build () }
  in
  let acts = actions_from_prices strat prices in
  let n_total = List.length acts in
  let n_hold = List.length (List.filter (fun a -> a = Signal.Hold) acts) in
  Alcotest.(check bool) "produces some signals" true (n_hold < n_total);
  Alcotest.(check bool) "doesn't signal every bar" true (n_hold > 0)

let test_mock_predictor () =
  let always_long : Strategies.Composite.predictor =
   fun ~signals:_ ~candle:_ ~recent_closes:_ ~recent_volumes:_ -> 0.9
  in
  let strat =
    Strategies.Strategy.make
      (module Strategies.Composite)
      Strategies.Composite.
        {
          policy = Learned { predict = always_long; threshold = 0.6 };
          children = children_build ();
        }
  in
  let acts = actions_from_prices strat (List.init 10 (fun _ -> 100.0)) in
  Alcotest.(check bool)
    "mock predictor → all Enter_long" true
    (List.for_all (fun a -> a = Signal.Enter_long) acts)

let tests =
  [
    ("learned produces signals", `Quick, test_learned_produces_signals);
    ("mock predictor override", `Quick, test_mock_predictor);
  ]

(** Unit tests for [Logistic_regression.Trainer] — walk-forward
    training produces valid weights without lookahead bias. *)

open Core

let mk_candles prices =
  List.mapi
    (fun i p ->
      let px = Decimal.of_float p in
      Candle.make
        ~ts:(Int64.of_int (i * 60))
        ~open_:px ~high:px ~low:px ~close:px ~volume:(Decimal.of_int 100))
    prices

let children () =
  [
    Strategies.Strategy.default (module Strategies.Sma_crossover);
    Strategies.Strategy.default (module Strategies.Rsi_mean_reversion);
  ]

let test_smoke () =
  let prices = List.init 200 (fun i -> 50.0 +. (10.0 *. sin (float_of_int i /. 10.0))) in
  let result =
    Logistic_regression.Trainer.train ~children:(children ()) ~candles:(mk_candles prices)
      ~lookahead:5 ~epochs:5 ()
  in
  Alcotest.(check bool) "produced weights" true (Array.length result.weights > 0);
  Alcotest.(check bool) "train_loss finite" true (Float.is_finite result.train_loss);
  Alcotest.(check bool) "val_loss finite" true (Float.is_finite result.val_loss);
  Alcotest.(check bool) "has training samples" true (result.n_train > 0);
  Alcotest.(check bool) "has validation samples" true (result.n_val > 0)

let test_too_few_bars () =
  let prices = List.init 5 (fun _ -> 100.0) in
  let result =
    Logistic_regression.Trainer.train ~children:(children ()) ~candles:(mk_candles prices)
      ~lookahead:3 ~epochs:5 ()
  in
  Alcotest.(check bool) "too few bars → no training" true (result.n_train = 0)

let test_train_val_split () =
  let prices = List.init 300 (fun i -> 50.0 +. (15.0 *. sin (float_of_int i /. 8.0))) in
  let result =
    Logistic_regression.Trainer.train ~children:(children ()) ~candles:(mk_candles prices)
      ~lookahead:5 ~epochs:5 ()
  in
  Alcotest.(check bool) "train > val (70/30 split)" true (result.n_train > result.n_val)

let tests =
  [
    ("trainer smoke", `Quick, test_smoke);
    ("too few bars", `Quick, test_too_few_bars);
    ("train/val split 70/30", `Quick, test_train_val_split);
  ]

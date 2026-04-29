(** Unit tests for [Logistic_regression.Features] — feature vector
    shape and correct encoding of signals + market context. *)

open Core

let test_shape () =
  Alcotest.(check int)
    "4 children → 10 features" 10
    (Logistic_regression.Features.n_features ~n_children:4);
  Alcotest.(check int)
    "2 children → 6 features" 6
    (Logistic_regression.Features.n_features ~n_children:2);
  Alcotest.(check int)
    "0 children → 2 features" 2
    (Logistic_regression.Features.n_features ~n_children:0)

let inst = Instrument.make ~ticker:(Ticker.of_string "X") ~venue:(Mic.of_string "MISX") ()

let mk_sig action strength =
  {
    Signal.ts = 0L;
    instrument = inst;
    action;
    strength;
    stop_loss = None;
    take_profit = None;
    reason = "";
  }

let test_extraction () =
  let signals = [ mk_sig Signal.Enter_long 0.8; mk_sig Signal.Hold 0.0 ] in
  let candle =
    Candle.make ~ts:0L ~open_:(Decimal.of_float 100.0) ~high:(Decimal.of_float 101.0)
      ~low:(Decimal.of_float 99.0) ~close:(Decimal.of_float 100.5)
      ~volume:(Decimal.of_float 1000.0)
  in
  let f =
    Logistic_regression.Features.extract ~signals ~candle
      ~recent_closes:[ 100.0; 99.0; 101.0 ] ~recent_volumes:[ 800.0; 900.0; 1000.0 ]
  in
  Alcotest.(check int)
    "length matches n_features"
    (Logistic_regression.Features.n_features ~n_children:2)
    (Array.length f);
  Alcotest.(check (float 1e-6)) "Enter_long → +1" 1.0 f.(0);
  Alcotest.(check (float 1e-6)) "strength of first" 0.8 f.(1);
  Alcotest.(check (float 1e-6)) "Hold → 0" 0.0 f.(2);
  Alcotest.(check (float 1e-6)) "Hold strength" 0.0 f.(3)

let test_short_signal () =
  let signals = [ mk_sig Signal.Enter_short 0.6 ] in
  let candle =
    Candle.make ~ts:0L ~open_:(Decimal.of_float 100.0) ~high:(Decimal.of_float 100.0)
      ~low:(Decimal.of_float 100.0) ~close:(Decimal.of_float 100.0)
      ~volume:(Decimal.of_float 500.0)
  in
  let f =
    Logistic_regression.Features.extract ~signals ~candle ~recent_closes:[]
      ~recent_volumes:[]
  in
  Alcotest.(check (float 1e-6)) "Enter_short → -1" (-1.0) f.(0)

let tests =
  [
    ("feature vector shape", `Quick, test_shape);
    ("feature extraction", `Quick, test_extraction);
    ("short signal encoding", `Quick, test_short_signal);
  ]

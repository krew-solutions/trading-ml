open Ind_helpers

let uptrend_saturates () =
  let ind = Indicators.Rsi.make ~period:14 in
  let ind = feed ind
    (List.init 30 (fun i -> candle (float_of_int (i + 1)))) in
  Alcotest.(check bool) "rsi up ~ 100" true (scalar ind > 99.9)

let downtrend_saturates () =
  let ind = Indicators.Rsi.make ~period:14 in
  let ind = feed ind
    (List.init 30 (fun i -> candle (30.0 -. float_of_int i))) in
  Alcotest.(check bool) "rsi down ~ 0" true (scalar ind < 0.1)

let tests = [
  "uptrend → 100", `Quick, uptrend_saturates;
  "downtrend → 0",  `Quick, downtrend_saturates;
]

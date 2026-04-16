open Ind_helpers

let close_at_high () =
  let ind = Indicators.Ad.make () in
  let c = candle ~high:10.0 ~low:5.0 ~volume:100.0 10.0 in
  Alcotest.(check (float 1e-9)) "+volume" 100.0 (scalar (feed ind [c]))

let close_at_low () =
  let ind = Indicators.Ad.make () in
  let c = candle ~high:10.0 ~low:5.0 ~volume:100.0 5.0 in
  Alcotest.(check (float 1e-9)) "-volume" (-100.0) (scalar (feed ind [c]))

let close_at_mid () =
  let ind = Indicators.Ad.make () in
  let c = candle ~high:10.0 ~low:0.0 ~volume:100.0 5.0 in
  Alcotest.(check (float 1e-9)) "mid = 0" 0.0 (scalar (feed ind [c]))

let zero_range_safe () =
  let ind = Indicators.Ad.make () in
  let c = candle ~high:10.0 ~low:10.0 ~volume:100.0 10.0 in
  Alcotest.(check (float 1e-9)) "no div by zero" 0.0 (scalar (feed ind [c]))

let tests = [
  "close at high", `Quick, close_at_high;
  "close at low",  `Quick, close_at_low;
  "close at mid",  `Quick, close_at_mid;
  "zero range safe", `Quick, zero_range_safe;
]

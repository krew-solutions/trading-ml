open Ind_helpers

let accumulates_on_close_at_high () =
  (* close at high on every bar → delta = +volume every bar *)
  let ind = Indicators.Cvd.make () in
  let ind = feed ind (List.init 5 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 10.0)) in
  Alcotest.(check (float 1e-9)) "cvd = 500" 500.0 (scalar ind)

let distributes_on_close_at_low () =
  let ind = Indicators.Cvd.make () in
  let ind = feed ind (List.init 3 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 0.0)) in
  Alcotest.(check (float 1e-9)) "cvd = -300" (-300.0) (scalar ind)

let midpoint_is_zero_delta () =
  let ind = Indicators.Cvd.make () in
  let ind = feed ind (List.init 10 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 5.0)) in
  Alcotest.(check (float 1e-9)) "cvd stays 0" 0.0 (scalar ind)

let zero_range_safe () =
  let ind = Indicators.Cvd.make () in
  let ind = feed ind [candle ~high:10.0 ~low:10.0 ~volume:100.0 10.0] in
  Alcotest.(check (float 1e-9)) "no div by zero" 0.0 (scalar ind)

let tests = [
  "close at high → +Σvol", `Quick, accumulates_on_close_at_high;
  "close at low → -Σvol",  `Quick, distributes_on_close_at_low;
  "midpoint → 0 delta",    `Quick, midpoint_is_zero_delta;
  "zero range safe",       `Quick, zero_range_safe;
]

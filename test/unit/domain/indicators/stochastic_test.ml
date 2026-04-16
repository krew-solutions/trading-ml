open Ind_helpers

let close_at_high () =
  let ind = Indicators.Stochastic.make ~k_period:14 ~d_period:3 () in
  let ind = feed ind
    (List.init 20 (fun _ -> candle ~high:23.0 ~low:0.0 23.0)) in
  match values ind with
  | [k; _] -> Alcotest.(check (float 1e-9)) "%k = 100" 100.0 k
  | _ -> Alcotest.fail "no output"

let close_at_low () =
  let ind = Indicators.Stochastic.make ~k_period:14 ~d_period:3 () in
  let ind = feed ind
    (List.init 20 (fun _ -> candle ~high:23.0 ~low:0.0 0.0)) in
  match values ind with
  | [k; _] -> Alcotest.(check (float 1e-9)) "%k = 0" 0.0 k
  | _ -> Alcotest.fail "no output"

let flat_range_fallback () =
  let ind = Indicators.Stochastic.make ~k_period:14 ~d_period:3 () in
  let ind = feed ind
    (List.init 20 (fun _ -> candle ~high:5.0 ~low:5.0 5.0)) in
  match values ind with
  | [k; _] -> Alcotest.(check (float 1e-9)) "fallback 50" 50.0 k
  | _ -> Alcotest.fail "no output"

let tests = [
  "close at high → 100", `Quick, close_at_high;
  "close at low → 0",    `Quick, close_at_low;
  "flat range → 50",     `Quick, flat_range_fallback;
]

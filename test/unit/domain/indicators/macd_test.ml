open Ind_helpers

let produces_output () =
  let ind = Indicators.Macd.make ~fast:3 ~slow:6 ~signal:2 () in
  let ind = feed ind (List.init 30 (fun i ->
    candle (50.0 +. sin (float_of_int i /. 3.0) *. 5.0))) in
  match values ind with
  | [_; _; _] -> ()
  | _ -> Alcotest.fail "MACD produced no value"

let hist_is_macd_minus_signal () =
  let ind = Indicators.Macd.make ~fast:3 ~slow:6 ~signal:2 () in
  let ind = feed ind (List.init 40 (fun i ->
    candle (100.0 +. float_of_int i))) in
  match values ind with
  | [m; s; h] ->
    Alcotest.(check (float 1e-9)) "hist" (m -. s) h
  | _ -> Alcotest.fail "no output"

let tests = [
  "produces three lines", `Quick, produces_output;
  "hist = macd - signal", `Quick, hist_is_macd_minus_signal;
]

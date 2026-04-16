open Ind_helpers

let trend_sign () =
  (* Uptrend: fast WMA > slow WMA → positive macd line. *)
  let ind = Indicators.Macd_weighted.make ~fast:5 ~slow:13 ~signal:4 () in
  let ind = feed ind
    (List.init 60 (fun i -> candle (100.0 +. float_of_int i))) in
  match values ind with
  | [m; _; _] -> Alcotest.(check bool) "macd-w > 0 on uptrend" true (m > 0.0)
  | _ -> Alcotest.fail "no output"

let flat_is_zero () =
  let ind = Indicators.Macd_weighted.make ~fast:5 ~slow:13 ~signal:4 () in
  let ind = feed ind (List.init 40 (fun _ -> candle 50.0)) in
  match values ind with
  | [m; s; h] ->
    Alcotest.(check (float 1e-9)) "macd"   0.0 m;
    Alcotest.(check (float 1e-9)) "signal" 0.0 s;
    Alcotest.(check (float 1e-9)) "hist"   0.0 h
  | _ -> Alcotest.fail "no output"

let tests = [
  "trend sign", `Quick, trend_sign;
  "flat → zeros", `Quick, flat_is_zero;
]

(** Unit tests for {!Vol_state} rolling stdev estimator. *)

module Vol = Portfolio_management.Common.Volatility
module VS = Portfolio_management.Common.Vol_state

let dec = Decimal.of_string

let af_daily = 252.0

let test_init_rejects_small_window () =
  Alcotest.check_raises "window=2 rejected" (Invalid_argument "") (fun () ->
      try
        let _ = VS.init ~window:2 ~annualisation_factor:af_daily in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_init_rejects_nonpositive_factor () =
  Alcotest.check_raises "factor=0 rejected" (Invalid_argument "") (fun () ->
      try
        let _ = VS.init ~window:10 ~annualisation_factor:0.0 in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_current_is_none_before_warmup () =
  let s = VS.init ~window:5 ~annualisation_factor:af_daily in
  let s = VS.update s ~close:(dec "100") in
  let s = VS.update s ~close:(dec "101") in
  Alcotest.(check bool) "warmup pending: none" true (VS.current s = None)

let test_current_some_after_warmup () =
  let s = VS.init ~window:4 ~annualisation_factor:af_daily in
  let s =
    List.fold_left
      (fun acc px -> VS.update acc ~close:(dec px))
      s
      [ "100"; "101"; "102"; "103" ]
  in
  Alcotest.(check bool) "current is Some after window full" true (VS.current s <> None)

let test_update_rejects_nonpositive_close () =
  let s = VS.init ~window:5 ~annualisation_factor:af_daily in
  Alcotest.check_raises "negative close rejected" (Invalid_argument "") (fun () ->
      try
        let _ = VS.update s ~close:(dec "-1") in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_constant_series_has_zero_vol () =
  let s = VS.init ~window:5 ~annualisation_factor:af_daily in
  let s =
    List.fold_left
      (fun acc px -> VS.update acc ~close:(dec px))
      s
      [ "100"; "100"; "100"; "100"; "100" ]
  in
  match VS.current s with
  | None -> Alcotest.fail "expected Some"
  | Some v ->
      Alcotest.(check string) "zero vol" "0" (Decimal.to_string (Vol.to_decimal v))

let test_sample_count_caps_at_window () =
  let s = VS.init ~window:3 ~annualisation_factor:af_daily in
  let s =
    List.fold_left
      (fun acc px -> VS.update acc ~close:(dec px))
      s
      [ "100"; "101"; "102"; "103"; "104" ]
  in
  Alcotest.(check int) "capped at window" 3 (VS.sample_count s)

let test_rising_series_has_positive_vol () =
  let s = VS.init ~window:4 ~annualisation_factor:af_daily in
  (* Geometric-like rise with mixed step sizes — non-zero return stdev *)
  let s =
    List.fold_left
      (fun acc px -> VS.update acc ~close:(dec px))
      s
      [ "100"; "110"; "120"; "150" ]
  in
  match VS.current s with
  | None -> Alcotest.fail "expected Some"
  | Some v ->
      Alcotest.(check bool) "positive vol" true (Decimal.is_positive (Vol.to_decimal v))

let tests =
  [
    Alcotest.test_case "init rejects window < 3" `Quick test_init_rejects_small_window;
    Alcotest.test_case "init rejects non-positive annualisation factor" `Quick
      test_init_rejects_nonpositive_factor;
    Alcotest.test_case "current = None before warmup" `Quick
      test_current_is_none_before_warmup;
    Alcotest.test_case "current = Some after warmup" `Quick test_current_some_after_warmup;
    Alcotest.test_case "update rejects non-positive close" `Quick
      test_update_rejects_nonpositive_close;
    Alcotest.test_case "constant series has zero volatility" `Quick
      test_constant_series_has_zero_vol;
    Alcotest.test_case "sample_count caps at window" `Quick
      test_sample_count_caps_at_window;
    Alcotest.test_case "rising series has positive volatility" `Quick
      test_rising_series_has_positive_vol;
  ]

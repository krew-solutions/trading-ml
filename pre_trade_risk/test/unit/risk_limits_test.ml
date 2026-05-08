(** Unit tests for {!Pre_trade_risk.Risk_limits}. *)

let d = Decimal.of_string

let test_make_accepts_valid () =
  let r =
    Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "100.0")
      ~max_gross_exposure:(d "10000.0") ~max_leverage:2.0
  in
  Alcotest.(check string)
    "min_cash" "100"
    (Decimal.to_string (Pre_trade_risk.Risk_limits.min_cash_buffer r));
  Alcotest.(check string)
    "max_gross" "10000"
    (Decimal.to_string (Pre_trade_risk.Risk_limits.max_gross_exposure r));
  Alcotest.(check (float 1e-9))
    "max_leverage" 2.0
    (Pre_trade_risk.Risk_limits.max_leverage r)

let test_make_rejects_negative_cash_buffer () =
  Alcotest.check_raises "negative buffer"
    (Invalid_argument "Risk_limits.make: min_cash_buffer must be >= 0") (fun () ->
      ignore
        (Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "-1.0")
           ~max_gross_exposure:(d "100.0") ~max_leverage:1.0))

let test_make_rejects_negative_gross () =
  Alcotest.check_raises "negative gross"
    (Invalid_argument "Risk_limits.make: max_gross_exposure must be >= 0") (fun () ->
      ignore
        (Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "0")
           ~max_gross_exposure:(d "-1.0") ~max_leverage:1.0))

let test_make_rejects_non_positive_leverage () =
  Alcotest.check_raises "zero leverage"
    (Invalid_argument "Risk_limits.make: max_leverage must be > 0") (fun () ->
      ignore
        (Pre_trade_risk.Risk_limits.make ~min_cash_buffer:(d "0")
           ~max_gross_exposure:(d "0") ~max_leverage:0.0))

let test_default_matches_legacy_constants () =
  (* Mirrors the old [Engine.Risk.default_limits]:
     min_cash_buffer = equity / 20
     max_gross_exposure = equity * 2
     max_leverage = 2.0
     max_per_instrument_notional was equity / 5 (now lives outside
     Risk_limits — exercised via Step.config separately). *)
  let equity = d "1000000" in
  let r = Pre_trade_risk.Risk_limits.default ~equity in
  Alcotest.(check string)
    "min_cash 5%" "50000"
    (Decimal.to_string (Pre_trade_risk.Risk_limits.min_cash_buffer r));
  Alcotest.(check string)
    "max_gross 200%" "2000000"
    (Decimal.to_string (Pre_trade_risk.Risk_limits.max_gross_exposure r));
  Alcotest.(check (float 1e-9))
    "max_leverage" 2.0
    (Pre_trade_risk.Risk_limits.max_leverage r)

let tests =
  [
    Alcotest.test_case "make accepts valid" `Quick test_make_accepts_valid;
    Alcotest.test_case "make rejects negative cash buffer" `Quick
      test_make_rejects_negative_cash_buffer;
    Alcotest.test_case "make rejects negative gross" `Quick
      test_make_rejects_negative_gross;
    Alcotest.test_case "make rejects non-positive leverage" `Quick
      test_make_rejects_non_positive_leverage;
    Alcotest.test_case "default matches legacy constants" `Quick
      test_default_matches_legacy_constants;
  ]

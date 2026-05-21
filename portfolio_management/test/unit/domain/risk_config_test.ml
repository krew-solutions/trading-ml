(** Unit tests for {!Risk_config} aggregate. *)

module Risk_config = Portfolio_management.Risk_config
module Risk_limits = Portfolio_management.Risk.Values.Risk_limits
module Book_id = Portfolio_management.Common.Book_id
module Source = Portfolio_management.Common.Source
module SPC = Portfolio_management.Common.Sizing_policy_choice
module Alpha_source_id = Portfolio_management.Common.Alpha_source_id
module Pair = Portfolio_management.Common.Pair

let book () = Book_id.of_string "book-α"
let dec = Decimal.of_string
let inst sym = Core.Instrument.of_qualified sym

let limits () =
  Risk_limits.make ~max_per_instrument_notional:(dec "100000")
    ~max_gross_exposure:(dec "500000")

let alpha_src () = Source.Alpha_view (Alpha_source_id.of_string "momentum-1")

let pair_src () =
  Source.Pair_mean_reversion (Pair.make ~a:(inst "SBER@MISX") ~b:(inst "GAZP@MISX"))

let default_sizing = SPC.Equity_proportional

let test_make_accepts_zero_one_boundary () =
  let _ =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:Decimal.zero
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:default_sizing
  in
  let _ =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:Decimal.one
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:default_sizing
  in
  let _ =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:default_sizing
  in
  Alcotest.(check pass) "constructed" () ()

let test_make_rejects_negative_fraction () =
  Alcotest.check_raises "negative" (Invalid_argument "") (fun () ->
      try
        let _ =
          Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "-0.01")
            ~limits:(limits ()) ~construction_source:(alpha_src ())
            ~sizing_policy:default_sizing
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_make_rejects_above_one_fraction () =
  Alcotest.check_raises "above 1" (Invalid_argument "") (fun () ->
      try
        let _ =
          Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "1.01")
            ~limits:(limits ()) ~construction_source:(alpha_src ())
            ~sizing_policy:default_sizing
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_make_accepts_vol_target () =
  let _ =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:(SPC.Volatility_target { target_annual_vol = dec "0.15" })
  in
  Alcotest.(check pass) "constructed" () ()

let test_make_rejects_negative_target_vol () =
  Alcotest.check_raises "negative target" (Invalid_argument "") (fun () ->
      try
        let _ =
          Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
            ~limits:(limits ()) ~construction_source:(alpha_src ())
            ~sizing_policy:(SPC.Volatility_target { target_annual_vol = dec "-0.05" })
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_sizing_policy_roundtrips () =
  let cfg =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:(SPC.Volatility_target { target_annual_vol = dec "0.10" })
  in
  Alcotest.(check bool)
    "vol_target" true
    (SPC.equal
       (Risk_config.sizing_policy cfg)
       (SPC.Volatility_target { target_annual_vol = dec "0.10" }))

let test_book_equity_is_linear () =
  let cfg =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:default_sizing
  in
  let be = Risk_config.book_equity cfg ~total_equity:(dec "1000000") in
  Alcotest.(check string) "300 000" "300000" (Decimal.to_string be)

let test_authorises_matches_only_same_source () =
  let cfg =
    Risk_config.make ~book_id:(book ()) ~risk_budget_fraction:(dec "0.3")
      ~limits:(limits ()) ~construction_source:(alpha_src ())
      ~sizing_policy:default_sizing
  in
  Alcotest.(check bool) "same source" true (Risk_config.authorises cfg (alpha_src ()));
  Alcotest.(check bool) "different kind" false (Risk_config.authorises cfg (pair_src ()));
  let other_alpha = Source.Alpha_view (Alpha_source_id.of_string "momentum-2") in
  Alcotest.(check bool)
    "different alpha id" false
    (Risk_config.authorises cfg other_alpha)

let tests =
  [
    Alcotest.test_case "make accepts [0,1] boundary" `Quick
      test_make_accepts_zero_one_boundary;
    Alcotest.test_case "make rejects negative fraction" `Quick
      test_make_rejects_negative_fraction;
    Alcotest.test_case "make rejects fraction > 1" `Quick
      test_make_rejects_above_one_fraction;
    Alcotest.test_case "make accepts Volatility_target sizing" `Quick
      test_make_accepts_vol_target;
    Alcotest.test_case "make rejects negative target_annual_vol" `Quick
      test_make_rejects_negative_target_vol;
    Alcotest.test_case "sizing_policy roundtrips through getter" `Quick
      test_sizing_policy_roundtrips;
    Alcotest.test_case "book_equity linear in total_equity" `Quick
      test_book_equity_is_linear;
    Alcotest.test_case "authorises matches only same source" `Quick
      test_authorises_matches_only_same_source;
  ]

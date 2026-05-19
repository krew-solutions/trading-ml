(** Unit tests for {!Build_target_on_construction_intent} —
    cover the load-bearing invariants of the unified pipeline:
    Risk_config absence → no-op; source mismatch → no-op
    (one-source-per-book invariant); happy path → sized and
    clipped target applied + IE published. *)

open Core
module Pm = Portfolio_management
module DEH = Portfolio_management_domain_event_handlers
module CI = Pm.Common.Construction_intent
module Source = Pm.Common.Source
module Strength = Pm.Common.Strength
module Direction = Pm.Common.Direction
module Book_id = Pm.Common.Book_id
module Alpha_source_id = Pm.Common.Alpha_source_id

let book () = Book_id.of_string "book-α"
let inst sym = Instrument.of_qualified sym
let dec = Decimal.of_string
let alpha_id () = Alpha_source_id.of_string "momentum-1"

let alpha_source () = Source.Alpha_view (alpha_id ())

let limits () =
  Pm.Risk.Values.Risk_limits.make
    ~max_per_instrument_notional:(Decimal.of_int 1_000_000_000)
    ~max_gross_exposure:(Decimal.of_int 1_000_000_000)

let risk_config ?(construction_source = alpha_source ())
    ?(risk_budget_fraction = dec "0.1") () =
  Pm.Risk_config.make ~book_id:(book ()) ~risk_budget_fraction
    ~limits:(limits ()) ~construction_source
    ~sizing_policy:Pm.Common.Sizing_policy_choice.Equity_proportional

let mark_table tbl _book i =
  match List.find_opt (fun (s, _) -> Instrument.equal s i) tbl with
  | Some (_, p) -> p
  | None -> Decimal.zero

let no_vol _ = None

let sizing_fn _book : DEH.Build_target_on_construction_intent.sizing_fn =
  fun ~book_equity ~mark ~volatility intent ->
    Pm.Sizing_policy.Equity_proportional.size () ~book_equity ~mark
      ~volatility intent

let make_scalar_intent ~instrument ~direction ~strength =
  CI.scalar ~book_id:(book ()) ~instrument ~direction
    ~strength:(Strength.of_decimal strength) ~source:(alpha_source ())
    ~observed_at:1L

let test_no_risk_config_silent_noop () =
  let i = inst "SBER@MISX" in
  let intent = make_scalar_intent ~instrument:i ~direction:Direction.Up
    ~strength:(dec "0.5")
  in
  let tp = ref (Pm.Target_portfolio.empty (book ())) in
  let published = ref 0 in
  DEH.Build_target_on_construction_intent.handle
    ~risk_config_for:(fun _ -> None)
    ~total_equity_for:(fun _ -> Decimal.of_int 100_000)
    ~mark_for:(mark_table [ (i, Decimal.of_int 100) ])
    ~volatility_for:no_vol
    ~sizing_for:sizing_fn
    ~target_portfolio_for:(fun _ -> tp)
    ~publish_target_portfolio_updated:(fun _ -> incr published)
    intent;
  Alcotest.(check int) "no publications" 0 !published;
  Alcotest.(check int) "target portfolio unchanged" 0
    (List.length (Pm.Target_portfolio.positions !tp))

let test_unauthorised_source_silent_noop () =
  let i = inst "SBER@MISX" in
  let other_id = Alpha_source_id.of_string "momentum-2" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Up
      ~strength:(Strength.of_decimal (dec "0.5"))
      ~source:(Source.Alpha_view other_id) ~observed_at:1L
  in
  let cfg = risk_config () in
  let tp = ref (Pm.Target_portfolio.empty (book ())) in
  let published = ref 0 in
  DEH.Build_target_on_construction_intent.handle
    ~risk_config_for:(fun _ -> Some cfg)
    ~total_equity_for:(fun _ -> Decimal.of_int 100_000)
    ~mark_for:(mark_table [ (i, Decimal.of_int 100) ])
    ~volatility_for:no_vol
    ~sizing_for:sizing_fn
    ~target_portfolio_for:(fun _ -> tp)
    ~publish_target_portfolio_updated:(fun _ -> incr published)
    intent;
  Alcotest.(check int) "no publications" 0 !published;
  Alcotest.(check int) "target portfolio unchanged" 0
    (List.length (Pm.Target_portfolio.positions !tp))

let test_happy_path_sizes_clips_publishes () =
  let i = inst "SBER@MISX" in
  let intent =
    make_scalar_intent ~instrument:i ~direction:Direction.Up
      ~strength:(dec "0.5")
  in
  let cfg = risk_config () in
  let tp = ref (Pm.Target_portfolio.empty (book ())) in
  let published = ref [] in
  DEH.Build_target_on_construction_intent.handle
    ~risk_config_for:(fun _ -> Some cfg)
    ~total_equity_for:(fun _ -> Decimal.of_int 100_000)
    ~mark_for:(mark_table [ (i, Decimal.of_int 100) ])
    ~volatility_for:no_vol
    ~sizing_for:sizing_fn
    ~target_portfolio_for:(fun _ -> tp)
    ~publish_target_portfolio_updated:(fun ie -> published := ie :: !published)
    intent;
  Alcotest.(check int) "one publication" 1 (List.length !published);
  (* book_equity = 100_000 × 0.1 = 10_000; qty = 10_000 × 0.5 / 100 = 50 *)
  let qty = Pm.Target_portfolio.target_for !tp i in
  Alcotest.(check string) "target_qty" "50" (Decimal.to_string qty)

let test_per_instrument_clip_in_pipeline () =
  let i = inst "SBER@MISX" in
  let intent =
    make_scalar_intent ~instrument:i ~direction:Direction.Up
      ~strength:Decimal.one
  in
  let limits =
    Pm.Risk.Values.Risk_limits.make
      ~max_per_instrument_notional:(Decimal.of_int 1_000)
      ~max_gross_exposure:(Decimal.of_int 1_000_000_000)
  in
  let cfg =
    Pm.Risk_config.make ~book_id:(book ())
      ~risk_budget_fraction:(dec "0.1") ~limits
      ~construction_source:(alpha_source ())
      ~sizing_policy:Pm.Common.Sizing_policy_choice.Equity_proportional
  in
  let tp = ref (Pm.Target_portfolio.empty (book ())) in
  let published = ref 0 in
  DEH.Build_target_on_construction_intent.handle
    ~risk_config_for:(fun _ -> Some cfg)
    ~total_equity_for:(fun _ -> Decimal.of_int 100_000)
    ~mark_for:(mark_table [ (i, Decimal.of_int 100) ])
    ~volatility_for:no_vol
    ~sizing_for:sizing_fn
    ~target_portfolio_for:(fun _ -> tp)
    ~publish_target_portfolio_updated:(fun _ -> incr published)
    intent;
  (* Pre-clip qty = 10_000 × 1.0 / 100 = 100; pre-clip notional = 10_000.
     max_per_instrument_notional = 1_000 → qty clipped to 10. *)
  let qty = Pm.Target_portfolio.target_for !tp i in
  Alcotest.(check string) "qty clipped to 10" "10" (Decimal.to_string qty);
  Alcotest.(check int) "one publication" 1 !published

let tests =
  [
    Alcotest.test_case "no Risk_config → silent no-op" `Quick
      test_no_risk_config_silent_noop;
    Alcotest.test_case "unauthorised source → silent no-op" `Quick
      test_unauthorised_source_silent_noop;
    Alcotest.test_case "happy path: size, clip, publish" `Quick
      test_happy_path_sizes_clips_publishes;
    Alcotest.test_case "per-instrument cap applied in pipeline" `Quick
      test_per_instrument_clip_in_pipeline;
  ]

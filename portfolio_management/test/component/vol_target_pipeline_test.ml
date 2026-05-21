(** BDD specification for the volatility-target sizing pipeline.

    Demonstrates the full operator-driven path:
    - operator configures a book with [Volatility_target] sizing;
    - a market-data feed warms the per-instrument rolling-vol
      estimator;
    - an alpha-source flip emits a {b non-zero} sized target —
      sized according to the vol-target formula rather than the
      raw equity-weighted notional.

    Critical refusal property is also exercised: before the vol
    estimator has warmed up, a vol-target book emits a zero
    target on a direction flip. This is the sentinel guarantee
    {!Volatility_target} promises — the policy refuses to size
    without vol information rather than silently degrade to
    fixed-fractional. *)

module Gherkin = Gherkin_edsl
open Test_harness

let alpha_source_id = "strategy:vol_target_smoke/v1"
let instrument_str = "SBER@MISX"
let instrument = Core.Instrument.of_qualified instrument_str
let target_annual_vol = "0.15"

let configure_book ctx =
  let ctx =
    subscribe ctx ~alpha_source_id ~instrument:instrument_str ~book_id:book_alpha
  in
  let construction_source =
    Pm.Common.Source.Alpha_view (Pm.Common.Alpha_source_id.of_string alpha_source_id)
  in
  let ctx =
    set_risk_config ctx ~book_id:book_alpha
      ~risk_budget_fraction:(Decimal.of_string "0.5") ~construction_source
      ~sizing_policy:
        (Pm.Common.Sizing_policy_choice.Volatility_target
           { target_annual_vol = Decimal.of_string target_annual_vol })
  in
  let ctx = set_total_equity ctx ~book_id:book_alpha ~equity:(Decimal.of_int 1_000_000) in
  set_mark ctx ~book_id:book_alpha ~instrument ~price:(Decimal.of_int 100)

(* Stream [count] bars at deterministic alternating prices to
   give the rolling stdev a non-zero sample. Each tick advances
   ts by 60s. *)
let feed_warmup_bars ctx ~count =
  let rec loop i ctx =
    if i >= count then ctx
    else
      let ts = Int64.of_int (1_700_000_000 + (i * 60)) in
      let close = Decimal.of_string (Printf.sprintf "%d" (100 + (i mod 5))) in
      let ctx = feed_bar ctx ~instrument ~ts ~close in
      loop (i + 1) ctx
  in
  loop 0 ctx

let target_qty ctx = Pm.Target_portfolio.target_for !(ctx.target_portfolio) instrument

let cold_book_refuses_to_size =
  Gherkin.scenario
    "Before the volatility estimator has warmed up, a vol-target book emits a \
     zero-quantity target on a direction flip"
    fresh_ctx
    [
      Gherkin.given
        "book \"alpha\" is configured with Volatility_target sizing (target 15%), \
         subscribed to the alpha source, marked at 100, and no bars have arrived yet"
        configure_book;
      Gherkin.when_ "the alpha source reports an UP view at strength 0.5" (fun ctx ->
          define_alpha_view ctx ~alpha_source_id ~instrument:instrument_str
            ~direction:"UP" ~strength:0.5 ~price:"100" ~occurred_at:"100");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_define_alpha_view_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_
        "the resulting target quantity is zero (policy refused to size without vol)"
        (fun ctx ->
          Alcotest.(check bool)
            "target_qty is zero" true
            (Decimal.is_zero (target_qty ctx)));
    ]

let warm_book_sizes_to_vol_target =
  Gherkin.scenario
    "After bars have warmed the rolling-stdev estimator, a flip from FLAT to UP emits a \
     non-zero vol-aware target"
    fresh_ctx
    [
      Gherkin.given
        "book \"alpha\" is configured with Volatility_target sizing and bars have \
         streamed in to fill the vol window" (fun ctx ->
          ctx |> configure_book
          (* Window = 20 — feed enough non-constant bars to leave
             [current] in [Some] and the stdev strictly positive. *)
          |> feed_warmup_bars ~count:25);
      Gherkin.when_ "the alpha source reports an UP view at strength 0.5" (fun ctx ->
          define_alpha_view ctx ~alpha_source_id ~instrument:instrument_str
            ~direction:"UP" ~strength:0.5 ~price:"100" ~occurred_at:"2000");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_define_alpha_view_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_
        "the resulting target quantity is strictly positive (vol-aware sizing fired)"
        (fun ctx ->
          Alcotest.(check bool)
            "target_qty is positive" true
            (Decimal.is_positive (target_qty ctx)));
    ]

let feature =
  Gherkin.feature "Volatility target pipeline"
    [ cold_book_refuses_to_size; warm_book_sizes_to_vol_target ]

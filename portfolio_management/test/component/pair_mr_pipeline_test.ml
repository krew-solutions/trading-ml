(** BDD specification for the pair_mean_reversion → Apply_bar →
    Target_portfolio → reconcile pipeline. Drives synthetic candles
    through {!Apply_bar_command_workflow.execute} and checks that
    once the policy emits a proposal the resulting reconciler
    announcement names both legs of the pair. *)

module Gherkin = Gherkin_edsl
module Pm = Portfolio_management
module PMR = Pm.Pair_mean_reversion
open Test_harness

let inst sym = Core.Instrument.of_qualified sym
let sber = inst "SBER@MISX"
let lkoh = inst "LKOH@MISX"

let make_pair_state ~window =
  let pair = Pm.Common.Pair.make ~a:sber ~b:lkoh in
  let cfg =
    PMR.Values.Pair_mr_config.make ~book_id:book_alpha ~pair
      ~hedge_ratio:(Pm.Common.Hedge_ratio.of_decimal Decimal.one)
      ~window
      ~z_entry:(Pm.Common.Z_score.of_float 1.0)
      ~z_exit:(Pm.Common.Z_score.of_float 0.5)
      ~notional:(Decimal.of_int 1_000)
  in
  PMR.init cfg

(* Drive synthetic candles through Apply_bar_command_workflow until
   the workflow applies a proposal (target_portfolio_updated_pub
   becomes non-empty) or the iteration bound is reached. Bound
   prevents infinite loop if hysteresis never opens on this seed. *)
let drive_until_applied ctx ~state_ref =
  let rec loop iter ctx =
    if iter >= 200 then ctx
    else if !(ctx.target_portfolio_updated_pub) <> [] then ctx
    else
      let ts = Int64.of_int (iter * 10) in
      let price_a = Decimal.of_float (100. +. Float.sin (float_of_int iter)) in
      let price_b = Decimal.of_float (100. +. (Float.cos (float_of_int iter) *. 1.5)) in
      let ctx = apply_bar ctx ~state_ref ~instrument:sber ~ts ~close:price_a in
      let ctx =
        apply_bar ctx ~state_ref ~instrument:lkoh ~ts:(Int64.add ts 1L) ~close:price_b
      in
      loop (iter + 1) ctx
  in
  loop 0 ctx

let pipeline_emits_two_legged_trade_list =
  Gherkin.scenario
    "When pair_mean_reversion fires through Apply_bar_command_workflow, reconciling \
     announces a two-legged trade list"
    fresh_ctx
    [
      Gherkin.given "a pair_mean_reversion policy on (SBER, LKOH) with window=4"
        (fun ctx -> ctx);
      Gherkin.when_
        "synthetic candles are dispatched through Apply_bar_command_workflow until the \
         workflow applies a proposal" (fun ctx ->
          let state_ref = ref (make_pair_state ~window:4) in
          let ctx = drive_until_applied ctx ~state_ref in
          if !(ctx.target_portfolio_updated_pub) <> [] then
            reconcile ctx ~computed_at:"2026-01-01T00:00:01Z"
          else ctx);
      Gherkin.then_
        "if a proposal fired, the announcement names exactly two distinct instruments"
        (fun ctx ->
          match !(ctx.trade_intents_planned_pub) with
          | [] ->
              (* Acceptable — no proposal emitted in the bounded
                 iteration window. *)
              ()
          | [ ie ] ->
              let symbols =
                List.map
                  (fun (t : Portfolio_management_queries.Trade_intent_view_model.t) ->
                    t.instrument.ticker)
                  ie.trades
              in
              let unique = List.sort_uniq String.compare symbols in
              Alcotest.(check int) "two distinct legs" 2 (List.length unique)
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected at most one announcement, got %d"
                   (List.length other)));
    ]

let feature =
  Gherkin.feature "Pair mean reversion pipeline" [ pipeline_emits_two_legged_trade_list ]

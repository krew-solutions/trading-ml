(** BDD specification for reconciling actual vs target. *)

module Gherkin = Gherkin_edsl
open Test_harness

let one_position ~symbol ~qty : Portfolio_management_commands.Set_target_command.position
    =
  { instrument = symbol; target_qty = qty }

let empty_actual_emits_full_target_as_trades =
  Gherkin.scenario
    "Reconciling against an empty actual portfolio emits the full target as trades"
    fresh_ctx
    [
      Gherkin.given
        "a target [+10 SBER, -8 LKOH] for book \"alpha\" and an empty actual portfolio"
        (fun ctx ->
          ctx
          |> set_target ~source:"manual" ~proposed_at:"2026-01-01T00:00:00Z"
               ~positions:
                 [
                   one_position ~symbol:"SBER@MISX" ~qty:"10";
                   one_position ~symbol:"LKOH@MISX" ~qty:"-8";
                 ]);
      Gherkin.when_ "the reconciler runs" (fun ctx ->
          ctx |> reconcile ~computed_at:"2026-01-01T00:01:00Z");
      Gherkin.then_
        "one Trade_intents_planned integration event is announced with both legs"
        (fun ctx ->
          match !(ctx.trade_intents_planned_pub) with
          | [ ie ] ->
              Alcotest.(check int) "two trades" 2 (List.length ie.trades);
              Alcotest.(check string) "book_id" "alpha" ie.book_id;
              let by_symbol =
                List.map
                  (fun (t : Portfolio_management_queries.Trade_intent_view_model.t) ->
                    (t.instrument.ticker, t.side, t.quantity))
                  ie.trades
              in
              Alcotest.(check bool)
                "BUY 10 SBER present" true
                (List.mem ("SBER", "BUY", "10") by_symbol);
              Alcotest.(check bool)
                "SELL 8 LKOH present" true
                (List.mem ("LKOH", "SELL", "8") by_symbol)
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one announcement, got %d" (List.length other)));
    ]

let matching_actual_emits_no_trades =
  Gherkin.scenario "When actual already matches target, the announcement is empty"
    fresh_ctx
    [
      Gherkin.given "a target [+5 SBER] for book \"alpha\"" (fun ctx ->
          ctx
          |> set_target ~source:"manual" ~proposed_at:"2026-01-01T00:00:00Z"
               ~positions:[ one_position ~symbol:"SBER@MISX" ~qty:"5" ]);
      Gherkin.and_ "an actual position of +5 SBER" (fun ctx ->
          ctx
          |> project_position_changed ~instrument:"SBER@MISX" ~delta_qty:"5" ~new_qty:"5"
               ~avg_price:"100" ~occurred_at:"2026-01-01T00:00:30Z");
      Gherkin.when_ "the reconciler runs" (fun ctx ->
          ctx |> reconcile ~computed_at:"2026-01-01T00:01:00Z");
      Gherkin.then_ "one announcement carries an empty trade list" (fun ctx ->
          match !(ctx.trade_intents_planned_pub) with
          | [ ie ] -> Alcotest.(check int) "no trades" 0 (List.length ie.trades)
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one announcement, got %d" (List.length other)));
    ]

let feature =
  Gherkin.feature "Reconcile command"
    [ empty_actual_emits_full_target_as_trades; matching_actual_emits_no_trades ]

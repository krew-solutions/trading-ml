(** BDD specification for projecting upstream account events into PM's
    actual_portfolio model. *)

module Gherkin = Gherkin_edsl
open Test_harness

let position_changed_updates_actual =
  Gherkin.scenario
    "A Position_changed projection updates the actual portfolio for the right book"
    fresh_ctx
    [
      Gherkin.given "an empty actual_portfolio for book \"alpha\"" (fun ctx -> ctx);
      Gherkin.when_
        "a Position_changed for SBER arrives with delta=+5, new_qty=5, avg=100"
        (fun ctx ->
          ctx
          |> project_position_changed ~instrument:"SBER@MISX" ~delta_qty:"5" ~new_qty:"5"
               ~avg_price:"100" ~occurred_at:"2026-01-01T00:00:00Z");
      Gherkin.then_ "the actual portfolio shows position(SBER) = 5" (fun ctx ->
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          let qty =
            Portfolio_management.Actual_portfolio.position !(ctx.actual_portfolio) inst
          in
          Alcotest.(check string) "qty 5" "5" (Decimal.to_string qty));
      Gherkin.then_ "the projection result is Ok" (fun ctx ->
          match ctx.last_project_position_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected Ok");
    ]

let cash_changed_updates_actual =
  Gherkin.scenario "A Cash_changed projection updates the actual portfolio's cash balance"
    fresh_ctx
    [
      Gherkin.given "an empty actual_portfolio for book \"alpha\"" (fun ctx -> ctx);
      Gherkin.when_ "a Cash_changed arrives with delta=+1000 and new_balance=1000"
        (fun ctx ->
          ctx
          |> project_cash_changed ~delta:"1000" ~new_balance:"1000"
               ~occurred_at:"2026-01-01T00:00:00Z");
      Gherkin.then_ "cash equals 1000" (fun ctx ->
          let cash = Portfolio_management.Actual_portfolio.cash !(ctx.actual_portfolio) in
          Alcotest.(check string) "cash 1000" "1000" (Decimal.to_string cash));
    ]

let unknown_book_is_refused =
  Gherkin.scenario
    "A projection for an unknown book is refused without touching any state" fresh_ctx
    [
      Gherkin.given "a fresh portfolio_management context" (fun ctx -> ctx);
      Gherkin.when_ "a Position_changed for an unregistered book arrives" (fun ctx ->
          let cmd : Portfolio_management_commands.Project_position_changed_command.t =
            {
              book_id = "unknown";
              instrument = "SBER@MISX";
              delta_qty = "5";
              new_qty = "5";
              avg_price = "100";
              occurred_at = "2026-01-01T00:00:00Z";
            }
          in
          let result =
            Project_position_wf.execute ~actual_portfolio_for:(actual_portfolio_for ctx)
              cmd
          in
          { ctx with last_project_position_result = Some result });
      Gherkin.then_ "the projection is refused with Unknown_book" (fun ctx ->
          match ctx.last_project_position_result with
          | Some (Error [ Project_position_h.Unknown_book _ ]) -> ()
          | _ -> Alcotest.fail "expected Unknown_book");
    ]

let feature =
  Gherkin.feature "Projection of upstream account events"
    [
      position_changed_updates_actual;
      cash_changed_updates_actual;
      unknown_book_is_refused;
    ]

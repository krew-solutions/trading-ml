(** BDD specification for {!Commit_actual_fill_command} — the
    inbound command that records an upstream fill into PM's
    [Actual_portfolio] aggregate.

    Account publishes a single atomic [Reservation_filled]
    integration event carrying both the new cash balance and the
    new position snapshot. PM's ACL translates it into this
    command; the workflow advances cash and position together so
    no downstream reader ever sees a state that violates
    [equity = cash + Σ qty × mark]. *)

module Gherkin = Gherkin_edsl
open Test_harness

let fill_updates_position_and_cash_atomically =
  Gherkin.scenario "A fill commit sets the new position and the new cash atomically"
    fresh_ctx
    [
      Gherkin.given "an empty actual_portfolio for book \"alpha\"" (fun ctx -> ctx);
      Gherkin.when_
        "a fill for SBER arrives with new_position_quantity=5, new_avg_price=100, \
         new_cash=-500" (fun ctx ->
          ctx
          |> commit_actual_fill ~instrument:"SBER@MISX" ~new_position_quantity:"5"
               ~new_avg_price:"100" ~new_cash:"-500" ~occurred_at:"2026-01-01T00:00:00Z");
      Gherkin.then_ "the actual portfolio shows position(SBER) = 5 and cash = -500"
        (fun ctx ->
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          let qty =
            Portfolio_management.Actual_portfolio.position !(ctx.actual_portfolio) inst
          in
          let cash = Portfolio_management.Actual_portfolio.cash !(ctx.actual_portfolio) in
          Alcotest.(check string) "qty 5" "5" (Decimal.to_string qty);
          Alcotest.(check string) "cash -500" "-500" (Decimal.to_string cash));
      Gherkin.then_ "the commit result is Ok" (fun ctx ->
          match ctx.last_commit_actual_fill_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected Ok");
    ]

let closing_fill_prunes_position_and_releases_cash =
  Gherkin.scenario
    "A fill that closes a position prunes the entry and updates cash atomically" fresh_ctx
    [
      Gherkin.given "an actual_portfolio holding 10 SBER@MISX with cash = -1000"
        (fun ctx ->
          ctx
          |> commit_actual_fill ~instrument:"SBER@MISX" ~new_position_quantity:"10"
               ~new_avg_price:"100" ~new_cash:"-1000" ~occurred_at:"2026-01-01T00:00:00Z");
      Gherkin.when_ "a fill that closes the position arrives with new_cash=50" (fun ctx ->
          ctx
          |> commit_actual_fill ~instrument:"SBER@MISX" ~new_position_quantity:"0"
               ~new_avg_price:"0" ~new_cash:"50" ~occurred_at:"2026-01-01T00:00:01Z");
      Gherkin.then_ "the SBER entry is gone and cash equals 50" (fun ctx ->
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          let qty =
            Portfolio_management.Actual_portfolio.position !(ctx.actual_portfolio) inst
          in
          let cash = Portfolio_management.Actual_portfolio.cash !(ctx.actual_portfolio) in
          Alcotest.(check string) "qty 0" "0" (Decimal.to_string qty);
          Alcotest.(check string) "cash 50" "50" (Decimal.to_string cash);
          Alcotest.(check int)
            "no positions" 0
            (List.length
               (Portfolio_management.Actual_portfolio.positions !(ctx.actual_portfolio))));
    ]

let unknown_book_is_refused =
  Gherkin.scenario "A fill for an unknown book is refused without touching any state"
    fresh_ctx
    [
      Gherkin.given "a fresh portfolio_management context" (fun ctx -> ctx);
      Gherkin.when_ "a fill for an unregistered book arrives" (fun ctx ->
          let cmd : Portfolio_management_commands.Commit_actual_fill_command.t =
            {
              book_id = "unknown";
              instrument = "SBER@MISX";
              new_position_quantity = "5";
              new_avg_price = "100";
              new_cash = "-500";
              occurred_at = "2026-01-01T00:00:00Z";
            }
          in
          let result =
            Commit_actual_fill_wf.execute ~actual_portfolio_for:(actual_portfolio_for ctx)
              cmd
          in
          { ctx with last_commit_actual_fill_result = Some result });
      Gherkin.then_ "the commit is refused with Unknown_book" (fun ctx ->
          match ctx.last_commit_actual_fill_result with
          | Some (Error [ Commit_actual_fill_h.Unknown_book _ ]) -> ()
          | _ -> Alcotest.fail "expected Unknown_book");
    ]

let feature =
  Gherkin.feature "Commit actual fill command"
    [
      fill_updates_position_and_cash_atomically;
      closing_fill_prunes_position_and_releases_cash;
      unknown_book_is_refused;
    ]

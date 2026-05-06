(** BDD specification for setting a target portfolio.

    Covers the happy path (a fresh target replaces an empty book) and
    the idempotent path (a re-application of the same proposal records
    no changes). *)

module Gherkin = Gherkin_edsl
open Test_harness

let one_position ~symbol ~qty : Portfolio_management_commands.Set_target_command.position
    =
  { instrument = symbol; target_qty = qty }

let new_target_replaces_empty_book =
  Gherkin.scenario "A new target replaces an empty book and announces the update"
    fresh_ctx
    [
      Gherkin.given "an empty target_portfolio for book \"alpha\"" (fun ctx -> ctx);
      Gherkin.when_ "a target proposal of [+10 SBER, -8 LKOH] is set" (fun ctx ->
          ctx
          |> set_target ~source:"manual" ~proposed_at:"2026-01-01T00:00:00Z"
               ~positions:
                 [
                   one_position ~symbol:"SBER@MISX" ~qty:"10";
                   one_position ~symbol:"LKOH@MISX" ~qty:"-8";
                 ]);
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_set_target_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_
        "one Target_portfolio_updated integration event is announced for book \"alpha\""
        (fun ctx ->
          match !(ctx.target_portfolio_updated_pub) with
          | [ ie ] ->
              Alcotest.(check string) "book_id" "alpha" ie.book_id;
              Alcotest.(check int) "two changes" 2 (List.length ie.changed)
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one announcement, got %d" (List.length other)));
    ]

let same_proposal_emits_no_changes =
  Gherkin.scenario "Re-applying the same proposal records an empty changed set" fresh_ctx
    [
      Gherkin.given "a target_portfolio with [+10 SBER] for book \"alpha\"" (fun ctx ->
          ctx
          |> set_target ~source:"manual" ~proposed_at:"2026-01-01T00:00:00Z"
               ~positions:[ one_position ~symbol:"SBER@MISX" ~qty:"10" ]);
      Gherkin.when_ "the same proposal is set again" (fun ctx ->
          ctx
          |> set_target ~source:"manual" ~proposed_at:"2026-01-01T00:01:00Z"
               ~positions:[ one_position ~symbol:"SBER@MISX" ~qty:"10" ]);
      Gherkin.then_ "the second announcement records an empty changed set" (fun ctx ->
          match !(ctx.target_portfolio_updated_pub) with
          | second :: _first :: _ ->
              Alcotest.(check int) "no changes second time" 0 (List.length second.changed)
          | _ -> Alcotest.fail "expected at least two announcements");
    ]

let malformed_book_id_emits_no_ie =
  Gherkin.scenario "An empty book_id fails validation and announces nothing" fresh_ctx
    [
      Gherkin.given "a fresh portfolio_management context" (fun ctx -> ctx);
      Gherkin.when_ "a target is set with an empty book_id" (fun ctx ->
          let cmd : Portfolio_management_commands.Set_target_command.t =
            {
              book_id = "";
              source = "manual";
              proposed_at = "2026-01-01T00:00:00Z";
              positions = [];
            }
          in
          let publish e =
            ctx.target_portfolio_updated_pub := e :: !(ctx.target_portfolio_updated_pub)
          in
          let result =
            Set_target_wf.execute ~target_portfolio:ctx.target_portfolio
              ~publish_target_portfolio_updated:publish cmd
          in
          { ctx with last_set_target_result = Some result });
      Gherkin.then_ "the request is refused with a validation error" (fun ctx ->
          match ctx.last_set_target_result with
          | Some (Error [ Set_target_h.Validation (Set_target_h.Invalid_book_id "") ]) ->
              ()
          | _ -> Alcotest.fail "expected Validation Invalid_book_id");
      Gherkin.then_ "no Target_portfolio_updated event is announced" (fun ctx ->
          Alcotest.(check int)
            "no announcements" 0
            (List.length !(ctx.target_portfolio_updated_pub)));
    ]

let feature =
  Gherkin.feature "Set target command"
    [
      new_target_replaces_empty_book;
      same_proposal_emits_no_changes;
      malformed_book_id_emits_no_ie;
    ]

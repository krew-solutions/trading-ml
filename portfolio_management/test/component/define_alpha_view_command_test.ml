(** BDD specification for defining an alpha view.

    Demonstrates the full alpha → target chain inside PM:
    receiving a directional reading on a subscribed
    [(alpha_source, instrument)] flips the [Alpha_view] aggregate,
    fans out to subscribed books' target portfolios, and announces
    a [Target_portfolio_updated] integration event. Same-direction
    redefinitions and unsubscribed sources stay silent. *)

module Gherkin = Gherkin_edsl
open Test_harness

let alpha_source_id = "strategy:bollinger_revert/v1"
let instrument = "SBER@MISX"

let prepare_subscription ctx =
  let ctx = subscribe ctx ~alpha_source_id ~instrument ~book_id:book_alpha in
  set_notional_cap ctx ~book_id:book_alpha ~cap:(Decimal.of_int 10_000)

let bullish_view_triggers_long_target =
  Gherkin.scenario
    "A bullish view on a subscribed instrument triggers a long target update for the book"
    fresh_ctx
    [
      Gherkin.given
        "book \"alpha\" is subscribed to \"strategy:bollinger_revert/v1\" on SBER@MISX \
         with a notional cap of 10000"
        prepare_subscription;
      Gherkin.when_ "the alpha source reports an UP view at strength 0.5 and price 100"
        (fun ctx ->
          ctx
          |> define_alpha_view ~alpha_source_id ~instrument ~direction:"UP" ~strength:0.5
               ~price:"100" ~occurred_at:"10");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_define_alpha_view_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_
        "one Target_portfolio_updated event is announced with a positive SBER quantity"
        (fun ctx ->
          match !(ctx.target_portfolio_updated_pub) with
          | [ ie ] -> (
              Alcotest.(check string) "book_id" "alpha" ie.book_id;
              match ie.changed with
              | [ ch ] ->
                  Alcotest.(check string) "previous qty zero" "0" ch.previous_qty;
                  let new_qty = Decimal.of_string ch.new_qty in
                  Alcotest.(check bool)
                    "new_qty positive" true (Decimal.is_positive new_qty)
              | _ -> Alcotest.fail "expected one change")
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one announcement, got %d" (List.length other)));
    ]

let same_direction_redefinition_emits_no_target_update =
  Gherkin.scenario
    "Re-defining the same direction does not announce a second target update" fresh_ctx
    [
      Gherkin.given "book \"alpha\" is subscribed and has been told UP at strength 0.5"
        (fun ctx ->
          let ctx = prepare_subscription ctx in
          define_alpha_view ctx ~alpha_source_id ~instrument ~direction:"UP" ~strength:0.5
            ~price:"100" ~occurred_at:"10");
      Gherkin.when_ "the alpha source repeats UP at a higher strength" (fun ctx ->
          define_alpha_view ctx ~alpha_source_id ~instrument ~direction:"UP" ~strength:0.9
            ~price:"110" ~occurred_at:"20");
      Gherkin.then_ "still only the original announcement is on record" (fun ctx ->
          Alcotest.(check int)
            "single announcement" 1
            (List.length !(ctx.target_portfolio_updated_pub)));
    ]

let direction_flip_switches_target_sign =
  Gherkin.scenario
    "Flipping the view from UP to DOWN switches the target position to a short" fresh_ctx
    [
      Gherkin.given "book \"alpha\" is subscribed and has been told UP at strength 0.5"
        (fun ctx ->
          let ctx = prepare_subscription ctx in
          define_alpha_view ctx ~alpha_source_id ~instrument ~direction:"UP" ~strength:0.5
            ~price:"100" ~occurred_at:"10");
      Gherkin.when_ "the alpha source flips to DOWN at strength 0.5" (fun ctx ->
          define_alpha_view ctx ~alpha_source_id ~instrument ~direction:"DOWN"
            ~strength:0.5 ~price:"100" ~occurred_at:"20");
      Gherkin.then_ "a second announcement records SBER moving to a negative quantity"
        (fun ctx ->
          match !(ctx.target_portfolio_updated_pub) with
          | second :: _first :: _ -> (
              match second.changed with
              | [ ch ] ->
                  let new_qty = Decimal.of_string ch.new_qty in
                  Alcotest.(check bool)
                    "new_qty negative" true (Decimal.is_negative new_qty)
              | _ -> Alcotest.fail "expected one change in the second announcement")
          | _ -> Alcotest.fail "expected at least two announcements");
    ]

let unsubscribed_source_emits_nothing =
  Gherkin.scenario
    "A view from an alpha source no book is subscribed to announces nothing" fresh_ctx
    [
      Gherkin.given
        "no book is subscribed to \"strategy:bollinger_revert/v1\" on SBER@MISX"
        (fun ctx -> ctx);
      Gherkin.when_ "the alpha source reports an UP view" (fun ctx ->
          define_alpha_view ctx ~alpha_source_id ~instrument ~direction:"UP" ~strength:0.7
            ~price:"100" ~occurred_at:"10");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_define_alpha_view_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_ "no Target_portfolio_updated event is announced" (fun ctx ->
          Alcotest.(check int)
            "no announcements" 0
            (List.length !(ctx.target_portfolio_updated_pub)));
    ]

let feature =
  Gherkin.feature "Define alpha view command"
    [
      bullish_view_triggers_long_target;
      same_direction_redefinition_emits_no_target_update;
      direction_flip_switches_target_sign;
      unsubscribed_source_emits_nothing;
    ]

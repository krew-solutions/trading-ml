(** BDD specification for absorbing an upstream fill into a per-book
    Risk_view atomically. Covers the upsert of a new position with
    new cash, the replacement of an existing one, and zero-quantity
    pruning — all preserving the [equity = cash + Σ qty × mark]
    invariant by advancing the cash and position sides in the same
    step. *)

module Gherkin = Gherkin_edsl
open Test_harness

let dec_eq label expected actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s: %s = %s" label (Decimal.to_string expected)
       (Decimal.to_string actual))
    true
    (Decimal.equal expected actual)

let new_position_and_cash_advance_together =
  Gherkin.scenario
    "A fill against an unseen instrument sets both the position and the cash atomically"
    fresh_ctx
    [
      Gherkin.given "an empty book \"alpha\" with 10 000 cash" (fun ctx ->
          ctx |> seed_book ~book_id:"alpha" |> with_cash ~book_id:"alpha" ~cash:"10000");
      Gherkin.when_ "a fill of 10 SBER@MISX (avg 100, new_cash 9 000) is recorded"
        (fun ctx ->
          ctx
          |> record_fill ~book_id:"alpha" ~symbol:"SBER@MISX" ~new_position_quantity:"10"
               ~new_avg_price:"100" ~new_cash:"9000");
      Gherkin.then_ "the workflow completes without error" (fun ctx ->
          match ctx.last_record_fill_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected workflow success");
      Gherkin.then_ "the book's view holds 10 SBER@MISX and 9 000 cash" (fun ctx ->
          let r =
            risk_view_ref_for ctx (Pre_trade_risk.Common.Book_id.of_string "alpha")
          in
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          dec_eq "position quantity" (Decimal.of_int 10)
            (Pre_trade_risk.Risk_view.position !r inst);
          dec_eq "cash" (Decimal.of_int 9_000) (Pre_trade_risk.Risk_view.cash !r));
    ]

let zero_qty_prunes_and_releases_cash =
  Gherkin.scenario
    "A fill that closes a position prunes the entry and replaces cash atomically"
    fresh_ctx
    [
      Gherkin.given "a book \"alpha\" with 9 000 cash and 10 SBER@MISX" (fun ctx ->
          ctx
          |> with_cash ~book_id:"alpha" ~cash:"9000"
          |> with_position ~book_id:"alpha" ~symbol:"SBER@MISX" ~qty:"10" ~avg_price:"100");
      Gherkin.when_ "a fill driving the quantity to zero with new_cash 10 100 is recorded"
        (fun ctx ->
          ctx
          |> record_fill ~book_id:"alpha" ~symbol:"SBER@MISX" ~new_position_quantity:"0"
               ~new_avg_price:"0" ~new_cash:"10100");
      Gherkin.then_ "the position is removed and cash advances to the new balance"
        (fun ctx ->
          let r =
            risk_view_ref_for ctx (Pre_trade_risk.Common.Book_id.of_string "alpha")
          in
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          dec_eq "position quantity" Decimal.zero
            (Pre_trade_risk.Risk_view.position !r inst);
          Alcotest.(check int)
            "positions list is empty" 0
            (List.length (Pre_trade_risk.Risk_view.positions !r));
          dec_eq "cash" (Decimal.of_int 10_100) (Pre_trade_risk.Risk_view.cash !r));
    ]

let replace_existing_position_and_cash =
  Gherkin.scenario
    "A subsequent fill for an already-known instrument replaces both the entry and the \
     cash"
    fresh_ctx
    [
      Gherkin.given "a book \"alpha\" with 9 000 cash and 10 SBER@MISX" (fun ctx ->
          ctx
          |> with_cash ~book_id:"alpha" ~cash:"9000"
          |> with_position ~book_id:"alpha" ~symbol:"SBER@MISX" ~qty:"10" ~avg_price:"100");
      Gherkin.when_
        "a fill bringing the position to 25 SBER@MISX (avg 110, new_cash 7 350) is \
         recorded" (fun ctx ->
          ctx
          |> record_fill ~book_id:"alpha" ~symbol:"SBER@MISX" ~new_position_quantity:"25"
               ~new_avg_price:"110" ~new_cash:"7350");
      Gherkin.then_
        "the view holds exactly one entry for SBER@MISX with the new qty, and cash \
         matches" (fun ctx ->
          let r =
            risk_view_ref_for ctx (Pre_trade_risk.Common.Book_id.of_string "alpha")
          in
          let inst = Core.Instrument.of_qualified "SBER@MISX" in
          dec_eq "position quantity" (Decimal.of_int 25)
            (Pre_trade_risk.Risk_view.position !r inst);
          Alcotest.(check int)
            "positions list size" 1
            (List.length (Pre_trade_risk.Risk_view.positions !r));
          dec_eq "cash" (Decimal.of_int 7_350) (Pre_trade_risk.Risk_view.cash !r));
    ]

let feature =
  Gherkin.feature "Record fill command"
    [
      new_position_and_cash_advance_together;
      zero_qty_prunes_and_releases_cash;
      replace_existing_position_and_cash;
    ]

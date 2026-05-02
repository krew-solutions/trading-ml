(** Component tests for the Reserve command pipeline.

    Drives {!Reserve_command_workflow.execute} end-to-end:
    wire-format command in, portfolio mutation + outbound integration
    events out, [Rop.t] tail surfacing both validation and reservation
    failures. *)

module Gherkin = Gherkin_edsl
open Test_harness

let dec_eq label expected actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s: %s = %s" label (Decimal.to_string expected)
       (Decimal.to_string actual))
    true
    (Decimal.equal expected actual)

let dec_lt label ~strict_upper actual =
  Alcotest.(check bool)
    (Printf.sprintf "%s: %s < %s" label (Decimal.to_string actual)
       (Decimal.to_string strict_upper))
    true
    (Decimal.compare actual strict_upper < 0)

let contains_substring ~needle haystack =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else loop (i + 1)
  in
  loop 0

let buy_succeeds =
  Gherkin.scenario "BUY publishes Amount_reserved and decreases available_cash" fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "1% slippage buffer and 0.1% fee rate" (fun ctx ->
          ctx |> with_slippage ~buffer:"0.01" |> with_fee_rate ~rate:"0.001");
      Gherkin.when_ "a BUY for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the workflow result is Ok ()" (fun ctx ->
          match ctx.last_reserve_result with
          | Some (Ok ()) -> ()
          | Some (Error _) -> Alcotest.fail "expected Ok"
          | None -> Alcotest.fail "workflow not executed");
      Gherkin.then_ "exactly one Amount_reserved IE was published" (fun ctx ->
          match !(ctx.amount_reserved_pub) with
          | [ ie ] ->
              Alcotest.(check int) "reservation_id" 1 ie.reservation_id;
              Alcotest.(check string) "side" "BUY" ie.side;
              Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
              Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue;
              Alcotest.(check string) "quantity" "10" ie.quantity;
              Alcotest.(check string) "price" "100" ie.price
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected 1 Amount_reserved IE, got %d"
                   (List.length other)));
      Gherkin.then_ "no Reservation_rejected IE was published" (fun ctx ->
          Alcotest.(check int)
            "reservation_rejected count" 0
            (List.length !(ctx.reservation_rejected_pub)));
      Gherkin.then_ "cash is unchanged but available_cash dropped" (fun ctx ->
          dec_eq "cash" (Decimal.of_int 10_000) !(ctx.portfolio).cash;
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          dec_lt "available_cash" ~strict_upper:(Decimal.of_int 10_000) avail);
    ]

let successive_buys_get_monotonic_ids =
  Gherkin.scenario "Successive BUYs get monotonically increasing reservation_ids"
    fresh_ctx
    [
      Gherkin.given "a portfolio with enough cash for two BUYs" (fun ctx ->
          ctx |> with_cash ~cash:"100000");
      Gherkin.when_ "two BUYs are submitted" (fun ctx ->
          ctx
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100"
          |> reserve ~side:"BUY" ~symbol:"GAZP@MISX" ~quantity:"1" ~price:"100");
      Gherkin.then_ "two Amount_reserved IEs are published with ids 1 and 2" (fun ctx ->
          match !(ctx.amount_reserved_pub) with
          | [ second; first ] ->
              Alcotest.(check int) "first id" 1 first.reservation_id;
              Alcotest.(check int) "second id" 2 second.reservation_id
          | other ->
              Alcotest.fail (Printf.sprintf "expected 2 IEs, got %d" (List.length other)));
    ]

let buy_rejected_for_insufficient_cash =
  Gherkin.scenario "BUY with insufficient cash publishes Reservation_rejected" fresh_ctx
    [
      Gherkin.given "a portfolio with only 100 cash" (fun ctx ->
          ctx |> with_cash ~cash:"100");
      Gherkin.when_ "a BUY for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the workflow tail carries Reservation/Insufficient_cash" (fun ctx ->
          match ctx.last_reserve_result with
          | Some
              (Error
                 [
                   Reserve_h.Reservation
                     {
                       error = Account.Portfolio.Insufficient_cash _;
                       attempted = { side = Core.Side.Buy; _ };
                     };
                 ]) -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "one Reservation_rejected IE was published, with the right reason"
        (fun ctx ->
          match !(ctx.reservation_rejected_pub) with
          | [ ie ] ->
              Alcotest.(check string) "side" "BUY" ie.side;
              Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
              Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue;
              Alcotest.(check string) "quantity" "10" ie.quantity;
              Alcotest.(check bool)
                (Printf.sprintf "reason mentions insufficient cash (got %S)" ie.reason)
                true
                (contains_substring ~needle:"insufficient cash" ie.reason)
          | other ->
              Alcotest.fail (Printf.sprintf "expected 1 IE, got %d" (List.length other)));
      Gherkin.then_ "no Amount_reserved IE was published" (fun ctx ->
          Alcotest.(check int)
            "amount_reserved count" 0
            (List.length !(ctx.amount_reserved_pub)));
    ]

let sell_rejected_without_position =
  Gherkin.scenario
    "SELL without a position publishes Reservation_rejected (Insufficient_qty)" fresh_ctx
    [
      Gherkin.given "a portfolio with cash but no positions" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "a SELL for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"SELL" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the workflow tail carries Reservation/Insufficient_qty" (fun ctx ->
          match ctx.last_reserve_result with
          | Some
              (Error
                 [
                   Reserve_h.Reservation
                     {
                       error = Account.Portfolio.Insufficient_qty _;
                       attempted = { side = Core.Side.Sell; _ };
                     };
                 ]) -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "one Reservation_rejected IE was published, mentioning quantity"
        (fun ctx ->
          match !(ctx.reservation_rejected_pub) with
          | [ ie ] ->
              Alcotest.(check string) "side" "SELL" ie.side;
              Alcotest.(check bool)
                (Printf.sprintf "reason mentions insufficient quantity (got %S)" ie.reason)
                true
                (contains_substring ~needle:"insufficient quantity" ie.reason)
          | other ->
              Alcotest.fail (Printf.sprintf "expected 1 IE, got %d" (List.length other)));
    ]

let malformed_symbol_emits_no_ie =
  Gherkin.scenario
    "Malformed symbol fails validation: nothing is published, only the Rop tail surfaces"
    fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a BUY with bare ticker (no @MIC) is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER" ~quantity:"1" ~price:"100");
      Gherkin.then_ "the workflow tail carries Validation/Invalid_symbol" (fun ctx ->
          match ctx.last_reserve_result with
          | Some (Error [ Reserve_h.Validation (Reserve_h.Invalid_symbol "SBER") ]) -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "no integration events were published on either port" (fun ctx ->
          Alcotest.(check int)
            "amount_reserved count" 0
            (List.length !(ctx.amount_reserved_pub));
          Alcotest.(check int)
            "reservation_rejected count" 0
            (List.length !(ctx.reservation_rejected_pub)));
      Gherkin.then_ "the portfolio ref is untouched" (fun ctx ->
          dec_eq "cash" (Decimal.of_int 10_000) !(ctx.portfolio).cash;
          Alcotest.(check int)
            "no reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let validation_errors_accumulate =
  Gherkin.scenario "Multiple wire-format errors accumulate, no IE published" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a command with bad side and non-positive quantity is sent"
        (fun ctx ->
          ctx |> reserve ~side:"NOPE" ~symbol:"SBER@MISX" ~quantity:"0" ~price:"100");
      Gherkin.then_ "both Invalid_side and Non_positive_quantity surface in the tail"
        (fun ctx ->
          match ctx.last_reserve_result with
          | Some (Error errs) ->
              let has_invalid_side =
                List.exists
                  (function
                    | Reserve_h.Validation (Reserve_h.Invalid_side "NOPE") -> true
                    | _ -> false)
                  errs
              in
              let has_non_positive_qty =
                List.exists
                  (function
                    | Reserve_h.Validation (Reserve_h.Non_positive_quantity "0") -> true
                    | _ -> false)
                  errs
              in
              Alcotest.(check bool) "Invalid_side present" true has_invalid_side;
              Alcotest.(check bool)
                "Non_positive_quantity present" true has_non_positive_qty
          | _ -> Alcotest.fail "expected Error in Rop tail");
      Gherkin.then_ "no integration events were published" (fun ctx ->
          Alcotest.(check int)
            "amount_reserved count" 0
            (List.length !(ctx.amount_reserved_pub));
          Alcotest.(check int)
            "reservation_rejected count" 0
            (List.length !(ctx.reservation_rejected_pub)));
    ]

let feature =
  Gherkin.feature "Reserve command"
    [
      buy_succeeds;
      successive_buys_get_monotonic_ids;
      buy_rejected_for_insufficient_cash;
      sell_rejected_without_position;
      malformed_symbol_emits_no_ie;
      validation_errors_accumulate;
    ]

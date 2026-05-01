(** Component tests for [Reserve_command_handler].

    Exercises the handler in-process against the real [Portfolio]
    aggregate, covering both railway tracks ([Validation] and
    [Reservation]) and the happy path. *)

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

let buy_succeeds =
  Gherkin.scenario "BUY reserves cash and emits Amount_reserved" fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "1% slippage buffer and 0.1% fee rate" (fun ctx ->
          ctx |> with_slippage ~buffer:"0.01" |> with_fee_rate ~rate:"0.001");
      Gherkin.when_ "a BUY for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "an Amount_reserved event is emitted" (fun ctx ->
          match ctx.last_event with
          | None -> Alcotest.fail "expected Amount_reserved"
          | Some ev ->
              Alcotest.(check int) "reservation_id" 1 ev.reservation_id;
              Alcotest.(check string)
                "instrument" "SBER@MISX"
                (Core.Instrument.to_qualified ev.instrument);
              dec_eq "quantity" (Decimal.of_int 10) ev.quantity;
              dec_eq "price" (Decimal.of_int 100) ev.price);
      Gherkin.then_ "available_cash dropped below the original 10 000" (fun ctx ->
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          dec_lt "available_cash" ~strict_upper:(Decimal.of_int 10_000) avail);
      Gherkin.then_ "cash itself is unchanged (only availability moves)" (fun ctx ->
          let cash = !(ctx.portfolio).cash in
          dec_eq "cash" (Decimal.of_int 10_000) cash);
    ]

let reservation_ids_are_monotonic =
  Gherkin.scenario "Successive reservations get monotonically increasing ids" fresh_ctx
    [
      Gherkin.given "a portfolio with enough cash for two BUYs" (fun ctx ->
          ctx |> with_cash ~cash:"100000");
      Gherkin.when_ "the first BUY is reserved" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100");
      Gherkin.then_ "its id is 1" (fun ctx ->
          match ctx.last_event with
          | Some ev -> Alcotest.(check int) "first id" 1 ev.reservation_id
          | None -> Alcotest.fail "expected first event");
      Gherkin.when_ "a second BUY is reserved" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"GAZP@MISX" ~quantity:"1" ~price:"100");
      Gherkin.then_ "its id is 2" (fun ctx ->
          match ctx.last_event with
          | Some ev -> Alcotest.(check int) "second id" 2 ev.reservation_id
          | None -> Alcotest.fail "expected second event");
    ]

let buy_rejected_for_insufficient_cash =
  Gherkin.scenario "BUY is rejected when cash is insufficient" fresh_ctx
    [
      Gherkin.given "a portfolio with only 100 cash" (fun ctx ->
          ctx |> with_cash ~cash:"100");
      Gherkin.when_ "a BUY for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the handler returns Reservation/Insufficient_cash" (fun ctx ->
          match ctx.last_errors with
          | Some
              [
                H.Reservation
                  {
                    error = Account.Portfolio.Insufficient_cash _;
                    attempted = { side = Core.Side.Buy; _ };
                  };
              ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
      Gherkin.then_ "no event was emitted" (fun ctx ->
          Alcotest.(check bool) "no event" true (Option.is_none ctx.last_event));
    ]

let sell_rejected_without_position =
  Gherkin.scenario "SELL is rejected when there is no position to sell" fresh_ctx
    [
      Gherkin.given "a portfolio with cash but no positions" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "a SELL for 10 SBER@MISX at 100 is submitted" (fun ctx ->
          ctx |> reserve ~side:"SELL" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the handler returns Reservation/Insufficient_qty" (fun ctx ->
          match ctx.last_errors with
          | Some
              [
                H.Reservation
                  {
                    error = Account.Portfolio.Insufficient_qty _;
                    attempted = { side = Core.Side.Sell; _ };
                  };
              ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
    ]

let malformed_symbol_fails_validation =
  Gherkin.scenario "Malformed symbol is rejected at validation" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a BUY with a bare ticker (no @MIC) is submitted" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER" ~quantity:"1" ~price:"100");
      Gherkin.then_ "the handler returns Validation/Invalid_symbol" (fun ctx ->
          match ctx.last_errors with
          | Some [ H.Validation (H.Invalid_symbol "SBER") ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
      Gherkin.then_ "the portfolio ref is untouched" (fun ctx ->
          dec_eq "cash" (Decimal.of_int 10_000) !(ctx.portfolio).cash;
          Alcotest.(check int)
            "no reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let validation_errors_accumulate =
  Gherkin.scenario "Multiple wire-format errors are reported together" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a command with bad side and non-positive quantity is sent"
        (fun ctx ->
          ctx |> reserve ~side:"NOPE" ~symbol:"SBER@MISX" ~quantity:"0" ~price:"100");
      Gherkin.then_ "both Invalid_side and Non_positive_quantity are surfaced" (fun ctx ->
          match ctx.last_errors with
          | Some errs ->
              let has_invalid_side =
                List.exists
                  (function
                    | H.Validation (H.Invalid_side "NOPE") -> true
                    | _ -> false)
                  errs
              in
              let has_non_positive_qty =
                List.exists
                  (function
                    | H.Validation (H.Non_positive_quantity "0") -> true
                    | _ -> false)
                  errs
              in
              Alcotest.(check bool) "Invalid_side present" true has_invalid_side;
              Alcotest.(check bool)
                "Non_positive_quantity present" true has_non_positive_qty
          | None -> Alcotest.fail "expected errors");
    ]

let feature =
  Gherkin.feature "Reserve command"
    [
      buy_succeeds;
      reservation_ids_are_monotonic;
      buy_rejected_for_insufficient_cash;
      sell_rejected_without_position;
      malformed_symbol_fails_validation;
      validation_errors_accumulate;
    ]

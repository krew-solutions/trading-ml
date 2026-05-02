(** Component tests for [Release_command_handler].

    Exercises the handler in-process against the real [Portfolio]
    aggregate, covering both railway tracks ([Validation] and
    [Release]) and the happy path. The happy-path setup uses
    {!Test_harness.reserve} to create a real reservation first —
    Release operates on aggregate state that only Reserve can
    legitimately produce. *)

module Gherkin = Gherkin_edsl
module H = Test_harness.Release_h
open Test_harness

let release_succeeds_after_reserve =
  Gherkin.scenario
    "Release of an existing reservation emits Reservation_released and restores \
     availability"
    fresh_ctx
    [
      Gherkin.given "a portfolio with cash" (fun ctx -> ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "a successful BUY reservation" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "the reservation id 1 is released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "a Reservation_released event with the same id is emitted" (fun ctx ->
          match ctx.last_release_event with
          | None -> Alcotest.fail "expected Reservation_released"
          | Some ev ->
              Alcotest.(check int) "reservation_id" 1 ev.reservation_id;
              Alcotest.(check string)
                "instrument" "SBER@MISX"
                (Core.Instrument.to_qualified ev.instrument));
      Gherkin.then_ "available_cash is back to the original 10 000" (fun ctx ->
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          Alcotest.(check bool)
            (Printf.sprintf "available_cash = 10000 (got %s)" (Decimal.to_string avail))
            true
            (Decimal.equal avail (Decimal.of_int 10_000)));
      Gherkin.then_ "no reservations remain in the portfolio" (fun ctx ->
          Alcotest.(check int)
            "reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let release_rejected_for_unknown_id =
  Gherkin.scenario "Release of a non-existent reservation returns Reservation_not_found"
    fresh_ctx
    [
      Gherkin.given "a portfolio with no reservations" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "release id 42 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:42);
      Gherkin.then_ "the handler returns Release/Reservation_not_found" (fun ctx ->
          match ctx.last_release_errors with
          | Some [ H.Release (Account.Portfolio.Reservation_not_found 42) ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
      Gherkin.then_ "no event was emitted" (fun ctx ->
          Alcotest.(check bool) "no event" true (Option.is_none ctx.last_release_event));
    ]

let double_release_rejects_second =
  Gherkin.scenario "Releasing the same id twice fails on the second attempt" fresh_ctx
    [
      Gherkin.given "a portfolio with one BUY reservation" (fun ctx ->
          ctx |> with_cash ~cash:"10000"
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100");
      Gherkin.and_ "the reservation has already been released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.when_ "the same id is released again" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "the handler returns Release/Reservation_not_found" (fun ctx ->
          match ctx.last_release_errors with
          | Some [ H.Release (Account.Portfolio.Reservation_not_found 1) ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
    ]

let zero_id_fails_validation =
  Gherkin.scenario "reservation_id = 0 is rejected at validation" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "release id 0 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:0);
      Gherkin.then_ "the handler returns Validation/Non_positive_reservation_id"
        (fun ctx ->
          match ctx.last_release_errors with
          | Some [ H.Validation (H.Non_positive_reservation_id 0) ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
    ]

let negative_id_fails_validation =
  Gherkin.scenario "Negative reservation_id is rejected at validation" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "release id -5 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:(-5));
      Gherkin.then_ "the handler returns Validation/Non_positive_reservation_id"
        (fun ctx ->
          match ctx.last_release_errors with
          | Some [ H.Validation (H.Non_positive_reservation_id -5) ] -> ()
          | Some _ -> Alcotest.fail "wrong error variant"
          | None -> Alcotest.fail "expected an error");
    ]

let feature =
  Gherkin.feature "Release command"
    [
      release_succeeds_after_reserve;
      release_rejected_for_unknown_id;
      double_release_rejects_second;
      zero_id_fails_validation;
      negative_id_fails_validation;
    ]

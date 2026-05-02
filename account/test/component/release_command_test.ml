(** Component tests for the Release command pipeline.

    Drives {!Release_command_workflow.execute} end-to-end: wire-format
    command in, portfolio mutation + (on success) the
    [Reservation_released] integration event published through the
    outbound port, [Rop.t] tail surfacing both validation and release
    failures.

    Note on the failure tracks: the workflow does NOT publish any
    [Reservation_rejected]-style integration event on a failed
    release — duplicated or late releases are treated as a
    contract violation and surface only via the [Rop.t] tail. The
    asserts below exercise that contract: on every failure scenario
    the recorder list stays empty. *)

module Gherkin = Gherkin_edsl
open Test_harness

let release_succeeds_after_reserve =
  Gherkin.scenario
    "Release of an existing reservation publishes Reservation_released and restores \
     availability"
    fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "a successful BUY reservation" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "the reservation id 1 is released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "the workflow result is Ok ()" (fun ctx ->
          match ctx.last_release_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected Ok");
      Gherkin.then_ "exactly one Reservation_released IE was published" (fun ctx ->
          match !(ctx.reservation_released_pub) with
          | [ ie ] ->
              Alcotest.(check int) "reservation_id" 1 ie.reservation_id;
              Alcotest.(check string) "side" "BUY" ie.side;
              Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
              Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue
          | other ->
              Alcotest.fail (Printf.sprintf "expected 1 IE, got %d" (List.length other)));
      Gherkin.then_ "available_cash is back to the original 10 000" (fun ctx ->
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          Alcotest.(check bool)
            (Printf.sprintf "avail = 10000 (got %s)" (Decimal.to_string avail))
            true
            (Decimal.equal avail (Decimal.of_int 10_000)));
      Gherkin.then_ "no reservations remain in the portfolio" (fun ctx ->
          Alcotest.(check int)
            "reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let release_rejected_for_unknown_id =
  Gherkin.scenario "Release of a non-existent reservation surfaces only via the Rop tail"
    fresh_ctx
    [
      Gherkin.given "a portfolio with no reservations" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "release id 42 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:42);
      Gherkin.then_ "the workflow tail carries Release/Reservation_not_found" (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Release (Account.Portfolio.Reservation_not_found 42) ])
            -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "no Reservation_released IE was published" (fun ctx ->
          Alcotest.(check int)
            "released count" 0
            (List.length !(ctx.reservation_released_pub)));
    ]

let double_release_rejects_second =
  Gherkin.scenario
    "Releasing the same id twice publishes only once and fails on the second attempt"
    fresh_ctx
    [
      Gherkin.given "a portfolio with one BUY reservation" (fun ctx ->
          ctx |> with_cash ~cash:"10000"
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100");
      Gherkin.and_ "the reservation has already been released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.when_ "the same id is released again" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "the workflow tail carries Release/Reservation_not_found" (fun ctx ->
          match ctx.last_release_result with
          | Some (Error [ Release_h.Release (Account.Portfolio.Reservation_not_found 1) ])
            -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "exactly one Reservation_released IE was published overall"
        (fun ctx ->
          Alcotest.(check int)
            "released count" 1
            (List.length !(ctx.reservation_released_pub)));
    ]

let zero_id_fails_validation =
  Gherkin.scenario "reservation_id = 0 is rejected at validation, no IE published"
    fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "release id 0 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:0);
      Gherkin.then_ "the workflow tail carries Validation/Non_positive_reservation_id"
        (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Validation (Release_h.Non_positive_reservation_id 0) ])
            -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "no IE was published" (fun ctx ->
          Alcotest.(check int)
            "released count" 0
            (List.length !(ctx.reservation_released_pub)));
    ]

let negative_id_fails_validation =
  Gherkin.scenario "Negative reservation_id is rejected at validation, no IE published"
    fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "release id -5 is submitted" (fun ctx ->
          ctx |> release ~reservation_id:(-5));
      Gherkin.then_ "the workflow tail carries Validation/Non_positive_reservation_id"
        (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Validation (Release_h.Non_positive_reservation_id -5) ])
            -> ()
          | _ -> Alcotest.fail "wrong Rop tail");
      Gherkin.then_ "no IE was published" (fun ctx ->
          Alcotest.(check int)
            "released count" 0
            (List.length !(ctx.reservation_released_pub)));
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

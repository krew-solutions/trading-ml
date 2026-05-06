(** BDD specification for releasing a previously placed reservation.

    Covers the happy path (cash freed, the release is announced) and
    the refusal scenarios — unknown id, double release, malformed id.

    Convention: a refused release is silent — no announcement is
    emitted on either outbound channel. The asserts below exercise
    that convention: on every refusal scenario the recorder list
    stays empty. *)

module Gherkin = Gherkin_edsl
open Test_harness

let release_succeeds_after_reserve =
  Gherkin.scenario "Releasing a reservation frees its cash and announces the release"
    fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "an existing buy reservation" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "the reservation is released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_release_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_ "the release is announced with the matching id, side and instrument"
        (fun ctx ->
          match !(ctx.reservation_released_pub) with
          | [ ie ] ->
              Alcotest.(check int) "reservation_id" 1 ie.reservation_id;
              Alcotest.(check string) "side" "BUY" ie.side;
              Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
              Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one release announcement, got %d"
                   (List.length other)));
      Gherkin.then_ "the spendable cash is back to the original 10 000" (fun ctx ->
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          Alcotest.(check bool)
            (Printf.sprintf "avail = 10000 (got %s)" (Decimal.to_string avail))
            true
            (Decimal.equal avail (Decimal.of_int 10_000)));
      Gherkin.then_ "the portfolio holds no reservations anymore" (fun ctx ->
          Alcotest.(check int)
            "reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let release_rejected_for_unknown_id =
  Gherkin.scenario "Releasing an unknown reservation is refused" fresh_ctx
    [
      Gherkin.given "a portfolio with no reservations" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "a release is requested for an unknown id" (fun ctx ->
          ctx |> release ~reservation_id:42);
      Gherkin.then_ "the request is refused as unknown" (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Release (Account.Portfolio.Reservation_not_found 42) ])
            -> ()
          | _ -> Alcotest.fail "expected refusal for unknown reservation");
      Gherkin.then_ "nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "released count" 0
            (List.length !(ctx.reservation_released_pub)));
    ]

let double_release_rejects_second =
  Gherkin.scenario "Releasing the same reservation twice is refused on the second attempt"
    fresh_ctx
    [
      Gherkin.given "a portfolio with a single buy reservation" (fun ctx ->
          ctx |> with_cash ~cash:"10000"
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100");
      Gherkin.and_ "that reservation has already been released" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.when_ "the same id is released again" (fun ctx ->
          ctx |> release ~reservation_id:1);
      Gherkin.then_ "the second request is refused as unknown" (fun ctx ->
          match ctx.last_release_result with
          | Some (Error [ Release_h.Release (Account.Portfolio.Reservation_not_found 1) ])
            -> ()
          | _ -> Alcotest.fail "expected refusal for unknown reservation");
      Gherkin.then_ "only the first release was ever announced" (fun ctx ->
          Alcotest.(check int)
            "released count" 1
            (List.length !(ctx.reservation_released_pub)));
    ]

let zero_id_fails_validation =
  Gherkin.scenario "A reservation id of zero is malformed and refused" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a release is requested with id 0" (fun ctx ->
          ctx |> release ~reservation_id:0);
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Validation (Release_h.Non_positive_reservation_id 0) ])
            -> ()
          | _ -> Alcotest.fail "expected refusal for malformed id");
      Gherkin.then_ "nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "released count" 0
            (List.length !(ctx.reservation_released_pub)));
    ]

let negative_id_fails_validation =
  Gherkin.scenario "A negative reservation id is malformed and refused" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a release is requested with id -5" (fun ctx ->
          ctx |> release ~reservation_id:(-5));
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_release_result with
          | Some
              (Error [ Release_h.Validation (Release_h.Non_positive_reservation_id -5) ])
            -> ()
          | _ -> Alcotest.fail "expected refusal for malformed id");
      Gherkin.then_ "nothing is announced" (fun ctx ->
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

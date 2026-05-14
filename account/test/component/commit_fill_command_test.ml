(** BDD specification for committing a fill against an existing
    reservation.

    Covers the happy path (the reservation matures, the atomic
    [Reservation_filled] is announced) and the refusal scenarios
    — malformed quantity / price / fee, missing reservation. *)

module Gherkin = Gherkin_edsl
open Test_harness

let commit_fill_after_reserve_announces_the_atomic_fill =
  Gherkin.scenario
    "Committing a fill against a reservation announces the new position and cash \
     atomically"
    fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "an existing buy reservation for 10 SBER@MISX at 100" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "the broker reports the fill at 100 with fee 1" (fun ctx ->
          ctx |> commit_fill ~reservation_id:1 ~quantity:"10" ~price:"100" ~fee:"1");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_commit_fill_result with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_
        "a single announcement carries the new position and the new cash together"
        (fun ctx ->
          match !(ctx.reservation_filled_pub) with
          | [ ie ] ->
              Alcotest.(check int) "reservation_id" 1 ie.reservation_id;
              Alcotest.(check string) "side" "BUY" ie.side;
              Alcotest.(check string) "instrument.ticker" "SBER" ie.instrument.ticker;
              Alcotest.(check string) "instrument.venue" "MISX" ie.instrument.venue;
              Alcotest.(check string) "filled_quantity" "10" ie.filled_quantity;
              Alcotest.(check string) "fill_price" "100" ie.fill_price;
              Alcotest.(check string) "fee" "1" ie.fee;
              Alcotest.(check string)
                "new_position_quantity" "10" ie.new_position_quantity;
              Alcotest.(check string) "new_avg_price" "100" ie.new_avg_price;
              Alcotest.(check string) "new_cash (10 000 - 10*100 - 1)" "8999" ie.new_cash
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one announcement, got %d" (List.length other)));
      Gherkin.then_
        "the reservation is consumed and the portfolio holds the long position"
        (fun ctx ->
          Alcotest.(check int)
            "reservations" 0
            (List.length !(ctx.portfolio).reservations);
          let instrument = Core.Instrument.of_qualified "SBER@MISX" in
          match Account.Portfolio.position !(ctx.portfolio) instrument with
          | Some pos ->
              Alcotest.(check string) "position qty" "10" (Decimal.to_string pos.quantity)
          | None -> Alcotest.fail "expected an open SBER@MISX position");
    ]

let commit_fill_rejected_for_already_released_reservation =
  Gherkin.scenario
    "Committing a fill against a reservation that was already released is refused"
    fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "a buy reservation that has already been released" (fun ctx ->
          ctx
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100"
          |> release ~reservation_id:1);
      Gherkin.when_ "a late fill arrives for the same reservation" (fun ctx ->
          ctx |> commit_fill ~reservation_id:1 ~quantity:"10" ~price:"100" ~fee:"1");
      Gherkin.then_ "the request is refused as unknown" (fun ctx ->
          match ctx.last_commit_fill_result with
          | Some
              (Error [ Commit_fill_h.Commit (Account.Portfolio.Reservation_not_found 1) ])
            -> ()
          | _ -> Alcotest.fail "expected refusal for unknown reservation");
      Gherkin.then_ "nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "reservation-filled count" 0
            (List.length !(ctx.reservation_filled_pub)));
      Gherkin.then_ "the portfolio cash is back to its pre-reservation 10 000" (fun ctx ->
          Alcotest.(check bool)
            "cash = 10000" true
            (Decimal.equal !(ctx.portfolio).cash (Decimal.of_int 10_000)));
    ]

let zero_id_fails_validation =
  Gherkin.scenario "A reservation id of zero is malformed and refused" fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a commit fill is requested with id 0" (fun ctx ->
          ctx |> commit_fill ~reservation_id:0 ~quantity:"10" ~price:"100" ~fee:"1");
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_commit_fill_result with
          | Some
              (Error
                 [
                   Commit_fill_h.Validation (Commit_fill_h.Non_positive_reservation_id 0);
                 ]) -> ()
          | _ -> Alcotest.fail "expected refusal for malformed id");
      Gherkin.then_ "nothing is announced" (fun ctx ->
          Alcotest.(check int)
            "reservation-filled count" 0
            (List.length !(ctx.reservation_filled_pub)));
    ]

let negative_fee_fails_validation =
  Gherkin.scenario "A negative fee is malformed and refused" fresh_ctx
    [
      Gherkin.given "a portfolio with an existing reservation" (fun ctx ->
          ctx |> with_cash ~cash:"10000"
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "a commit fill is requested with fee -1" (fun ctx ->
          ctx |> commit_fill ~reservation_id:1 ~quantity:"10" ~price:"100" ~fee:"-1");
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_commit_fill_result with
          | Some (Error errs)
            when List.exists
                   (function
                     | Commit_fill_h.Validation (Commit_fill_h.Negative_fee _) -> true
                     | _ -> false)
                   errs -> ()
          | _ -> Alcotest.fail "expected refusal for negative fee");
      Gherkin.then_ "nothing is announced and the portfolio is unchanged" (fun ctx ->
          Alcotest.(check int)
            "reservation-filled count" 0
            (List.length !(ctx.reservation_filled_pub));
          Alcotest.(check int)
            "reservations still 1" 1
            (List.length !(ctx.portfolio).reservations));
    ]

let non_positive_quantity_fails_validation =
  Gherkin.scenario "A zero quantity is malformed and refused" fresh_ctx
    [
      Gherkin.given "a portfolio with an existing reservation" (fun ctx ->
          ctx |> with_cash ~cash:"10000"
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.when_ "a commit fill is requested with quantity 0" (fun ctx ->
          ctx |> commit_fill ~reservation_id:1 ~quantity:"0" ~price:"100" ~fee:"1");
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_commit_fill_result with
          | Some (Error errs)
            when List.exists
                   (function
                     | Commit_fill_h.Validation (Commit_fill_h.Non_positive_quantity _) ->
                         true
                     | _ -> false)
                   errs -> ()
          | _ -> Alcotest.fail "expected refusal for non-positive quantity");
    ]

let feature =
  Gherkin.feature "Commit fill command"
    [
      commit_fill_after_reserve_announces_the_atomic_fill;
      commit_fill_rejected_for_already_released_reservation;
      zero_id_fails_validation;
      negative_fee_fails_validation;
      non_positive_quantity_fails_validation;
    ]

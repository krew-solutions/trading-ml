(** BDD specification for placing a reservation on the portfolio.

    Covers the happy path (cash earmarked, the reservation is
    announced) and the refusal scenarios — insufficient cash,
    insufficient quantity for sells, malformed instrument, and
    multiple malformed fields reported together. *)

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
  Gherkin.scenario "A buy reserves cash for the pending order and announces it" fresh_ctx
    [
      Gherkin.given "a portfolio with 10 000 cash" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.and_ "a 1% slippage buffer and a 0.1% fee rate" (fun ctx ->
          ctx |> with_slippage ~buffer:"0.01" |> with_fee_rate ~rate:"0.001");
      Gherkin.when_ "a buy of 10 SBER@MISX at 100 is requested" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the request is accepted" (fun ctx ->
          match ctx.last_reserve_result with
          | Some (Ok ()) -> ()
          | Some (Error _) -> Alcotest.fail "expected acceptance"
          | None -> Alcotest.fail "workflow not executed");
      Gherkin.then_
        "the reservation is announced with the matching side, instrument, quantity and \
         price" (fun ctx ->
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
                (Printf.sprintf "expected one reservation announcement, got %d"
                   (List.length other)));
      Gherkin.then_ "no refusal is announced" (fun ctx ->
          Alcotest.(check int)
            "reservation_rejected count" 0
            (List.length !(ctx.reservation_rejected_pub)));
      Gherkin.then_ "the cash balance is unchanged but the spendable cash drops"
        (fun ctx ->
          dec_eq "cash" (Decimal.of_int 10_000) !(ctx.portfolio).cash;
          let avail = Account.Portfolio.available_cash !(ctx.portfolio) in
          dec_lt "available_cash" ~strict_upper:(Decimal.of_int 10_000) avail);
    ]

let successive_buys_get_monotonic_ids =
  Gherkin.scenario "Each successive reservation is announced with its own ascending id"
    fresh_ctx
    [
      Gherkin.given "a portfolio with enough cash for two buys" (fun ctx ->
          ctx |> with_cash ~cash:"100000");
      Gherkin.when_ "two buys are placed in succession" (fun ctx ->
          ctx
          |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"1" ~price:"100"
          |> reserve ~side:"BUY" ~symbol:"GAZP@MISX" ~quantity:"1" ~price:"100");
      Gherkin.then_ "both reservations are announced, with ids assigned in order"
        (fun ctx ->
          match !(ctx.amount_reserved_pub) with
          | [ second; first ] ->
              Alcotest.(check int) "first id" 1 first.reservation_id;
              Alcotest.(check int) "second id" 2 second.reservation_id
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected two reservation announcements, got %d"
                   (List.length other)));
    ]

let buy_rejected_for_insufficient_cash =
  Gherkin.scenario "A buy is refused when the portfolio doesn't hold enough cash"
    fresh_ctx
    [
      Gherkin.given "a portfolio with only 100 cash" (fun ctx ->
          ctx |> with_cash ~cash:"100");
      Gherkin.when_ "a buy of 10 SBER@MISX at 100 is requested" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the request is refused for insufficient cash" (fun ctx ->
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
          | _ -> Alcotest.fail "unexpected response shape");
      Gherkin.then_
        "a refusal is announced carrying the original attempt and a human reason"
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
              Alcotest.fail
                (Printf.sprintf "expected one refusal announcement, got %d"
                   (List.length other)));
      Gherkin.then_ "no successful reservation is announced" (fun ctx ->
          Alcotest.(check int)
            "amount_reserved count" 0
            (List.length !(ctx.amount_reserved_pub)));
    ]

let sell_rejected_without_position =
  Gherkin.scenario "A sell is refused when the portfolio doesn't hold the instrument"
    fresh_ctx
    [
      Gherkin.given "a portfolio with cash but no open positions" (fun ctx ->
          ctx |> with_cash ~cash:"10000");
      Gherkin.when_ "a sell of 10 SBER@MISX at 100 is requested" (fun ctx ->
          ctx |> reserve ~side:"SELL" ~symbol:"SBER@MISX" ~quantity:"10" ~price:"100");
      Gherkin.then_ "the request is refused for insufficient quantity" (fun ctx ->
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
          | _ -> Alcotest.fail "unexpected response shape");
      Gherkin.then_ "a refusal is announced and the reason mentions quantity" (fun ctx ->
          match !(ctx.reservation_rejected_pub) with
          | [ ie ] ->
              Alcotest.(check string) "side" "SELL" ie.side;
              Alcotest.(check bool)
                (Printf.sprintf "reason mentions insufficient quantity (got %S)" ie.reason)
                true
                (contains_substring ~needle:"insufficient quantity" ie.reason)
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one refusal announcement, got %d"
                   (List.length other)));
    ]

let malformed_symbol_emits_no_ie =
  Gherkin.scenario "A malformed instrument is rejected silently, with no announcement"
    fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a buy is requested with an instrument that has no venue" (fun ctx ->
          ctx |> reserve ~side:"BUY" ~symbol:"SBER" ~quantity:"1" ~price:"100");
      Gherkin.then_ "the request is refused as malformed" (fun ctx ->
          match ctx.last_reserve_result with
          | Some (Error [ Reserve_h.Validation (Reserve_h.Invalid_symbol "SBER") ]) -> ()
          | _ -> Alcotest.fail "unexpected response shape");
      Gherkin.then_ "nothing is announced — neither a reservation nor a refusal"
        (fun ctx ->
          Alcotest.(check int)
            "amount_reserved count" 0
            (List.length !(ctx.amount_reserved_pub));
          Alcotest.(check int)
            "reservation_rejected count" 0
            (List.length !(ctx.reservation_rejected_pub)));
      Gherkin.then_ "the portfolio is left untouched" (fun ctx ->
          dec_eq "cash" (Decimal.of_int 10_000) !(ctx.portfolio).cash;
          Alcotest.(check int)
            "no reservations" 0
            (List.length !(ctx.portfolio).reservations));
    ]

let validation_errors_accumulate =
  Gherkin.scenario "All malformed fields are reported together, with no announcement"
    fresh_ctx
    [
      Gherkin.given "a default portfolio" (fun ctx -> ctx);
      Gherkin.when_ "a buy is requested with several malformed fields at once" (fun ctx ->
          ctx |> reserve ~side:"NOPE" ~symbol:"SBER@MISX" ~quantity:"0" ~price:"100");
      Gherkin.then_ "every malformed field is reported in a single response" (fun ctx ->
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
          | _ -> Alcotest.fail "expected a refusal");
      Gherkin.then_ "nothing is announced" (fun ctx ->
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

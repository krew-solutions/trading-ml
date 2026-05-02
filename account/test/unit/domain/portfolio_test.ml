open Core
module Portfolio = Account.Portfolio
module Position = Account.Portfolio.Values.Position

let d = Decimal.of_float

let dec =
  Alcotest.testable
    (fun fmt x -> Format.fprintf fmt "%s" (Decimal.to_string x))
    Decimal.equal

let inst =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

(* Default test policy: 50% margin / 50% haircut, same for every
   instrument. Concrete cases override one or the other when needed. *)
let stub_policy : Portfolio.Margin_policy.t =
 fun _ -> { margin_pct = d 0.5; haircut = d 0.5 }

(* No live mark in unit tests — domain falls back to avg_price. *)
let no_mark : Instrument.t -> Decimal.t option = fun _ -> None

let test_buy_decreases_cash () =
  let p = Portfolio.empty ~cash:(d 1000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 50.0)
      ~fee:(d 1.0)
  in
  Alcotest.(check bool) "cash decreased" true (Decimal.compare p.cash (d 499.0) = 0);
  match Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "qty" (d 10.0) pos.quantity;
      Alcotest.check dec "avg" (d 50.0) pos.avg_price
  | None -> Alcotest.fail "no position"

let test_partial_close_realizes_pnl () =
  let p = Portfolio.empty ~cash:(d 10000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Sell ~quantity:(d 5.0) ~price:(d 120.0)
      ~fee:Decimal.zero
  in
  Alcotest.check dec "realized 5*(120-100)=100" (d 100.0) p.realized_pnl;
  match Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "remaining qty" (d 5.0) pos.quantity;
      Alcotest.check dec "avg unchanged" (d 100.0) pos.avg_price
  | None -> Alcotest.fail "missing"

let test_equity_mark_to_market () =
  let p = Portfolio.empty ~cash:(d 1000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 50.0)
      ~fee:Decimal.zero
  in
  let mark i = if Instrument.equal i inst then Some (d 55.0) else None in
  Alcotest.check dec "equity" (d 1050.0) (Portfolio.equity p mark)

let test_flip_from_long_to_short () =
  let p = Portfolio.empty ~cash:(d 10000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 5.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Sell ~quantity:(d 8.0) ~price:(d 110.0)
      ~fee:Decimal.zero
  in
  Alcotest.check dec "realized" (d 50.0) p.realized_pnl;
  match Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "new qty -3" (d (-3.0)) pos.quantity;
      Alcotest.check dec "new avg = 110" (d 110.0) pos.avg_price
  | None -> Alcotest.fail "missing"

(* --- Reservations --- *)

let test_reserve_buy_reduces_available_cash () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:1 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:(d 0.01) ~fee_rate:(d 0.001)
      ~margin_policy:stub_policy
  in
  Alcotest.(check bool) "cash unchanged" true (Decimal.compare p.cash (d 10_000.0) = 0);
  Alcotest.(check (float 1e-3))
    "available cash" 8989.0
    (Decimal.to_float (Portfolio.available_cash p))

let test_reserve_sell_cover_only () =
  (* Long 20 @ 100, sell 5 — cover_qty = 5, open_qty = 0,
     no cash blocked, available_qty drops by 5. *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 20.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Portfolio.reserve p ~id:2 ~side:Sell ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  Alcotest.(check (float 1e-6)) "cash unchanged" 8000.0 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-6))
    "available_cash unchanged for cover-only sell" 8000.0
    (Decimal.to_float (Portfolio.available_cash p));
  Alcotest.(check (float 1e-6))
    "available_qty dropped by cover_qty" 15.0
    (Decimal.to_float (Portfolio.available_qty p inst))

let test_reserve_sell_open_only_passes_margin () =
  (* No position, sell 10 at 100 with margin_pct = 0.5.
     Cover = 0, open = 10, collateral = 10 * 100 * 0.5 = 500. *)
  let p = Portfolio.empty ~cash:(d 600.0) in
  match
    Portfolio.try_reserve p ~id:1 ~side:Sell ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy ~mark:no_mark
  with
  | Ok (p', ev) ->
      Alcotest.check dec "reserved_cash on event" (d 500.0) ev.reserved_cash;
      Alcotest.(check (float 1e-6))
        "available_cash drops by collateral" 100.0
        (Decimal.to_float (Portfolio.available_cash p'));
      Alcotest.(check (float 1e-6))
        "available_qty unaffected by open_qty" 0.0
        (Decimal.to_float (Portfolio.available_qty p' inst))
  | Error _ -> Alcotest.fail "expected acceptance"

let test_reserve_sell_open_only_fails_margin () =
  (* Same as above but cash 400 < required 500 → Insufficient_margin. *)
  let p = Portfolio.empty ~cash:(d 400.0) in
  match
    Portfolio.try_reserve p ~id:1 ~side:Sell ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy ~mark:no_mark
  with
  | Error (Insufficient_margin { required; available }) ->
      Alcotest.check dec "required" (d 500.0) required;
      Alcotest.check dec "available" (d 400.0) available
  | Error _ -> Alcotest.fail "wrong error variant"
  | Ok _ -> Alcotest.fail "expected refusal"

let test_reserve_sell_mixed_cover_and_open () =
  (* Long 6 @ 100, sell 10 with margin_pct = 0.5.
     Cover = 6, open = 4, collateral = 4 * 100 * 0.5 = 200. *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 6.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  match
    Portfolio.try_reserve p ~id:1 ~side:Sell ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy ~mark:no_mark
  with
  | Ok (p', ev) ->
      Alcotest.check dec "reserved_cash = open*price*margin_pct" (d 200.0)
        ev.reserved_cash;
      Alcotest.(check (float 1e-6))
        "available_qty drops by cover_qty only" 0.0
        (Decimal.to_float (Portfolio.available_qty p' inst))
  | Error _ -> Alcotest.fail "expected acceptance"

let test_reserve_sell_growing_short () =
  (* Already short -10, sell another 5: cover = 0, open = 5,
     collateral = 5 * 100 * 0.5 = 250. *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Sell ~quantity:(d 10.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  match
    Portfolio.try_reserve p ~id:1 ~side:Sell ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy ~mark:no_mark
  with
  | Ok (_p', ev) ->
      Alcotest.check dec "reserved_cash on adding to short" (d 250.0) ev.reserved_cash
  | Error _ -> Alcotest.fail "expected acceptance"

let test_commit_partial_fill_cover_first () =
  (* Long 6, sell 10 → cover=6, open=4. Partial fill 5 should
     deplete cover (5 of 6) leaving cover=1, open=4. Next partial
     fill 5 should deplete remaining cover=1 then 4 of open. *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 6.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p, _ =
    match
      Portfolio.try_reserve p ~id:1 ~side:Sell ~instrument:inst ~quantity:(d 10.0)
        ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
        ~margin_policy:stub_policy ~mark:no_mark
    with
    | Ok x -> x
    | Error _ -> Alcotest.fail "reserve must succeed"
  in
  let p =
    Portfolio.commit_partial_fill p ~id:1 ~actual_quantity:(d 5.0) ~actual_price:(d 100.0)
      ~actual_fee:Decimal.zero
  in
  (match p.reservations with
  | [ r ] ->
      Alcotest.check dec "cover_qty after first partial" (d 1.0) r.cover_qty;
      Alcotest.check dec "open_qty unchanged after first partial" (d 4.0) r.open_qty
  | _ -> Alcotest.fail "expected one reservation");
  let p =
    Portfolio.commit_partial_fill p ~id:1 ~actual_quantity:(d 5.0) ~actual_price:(d 100.0)
      ~actual_fee:Decimal.zero
  in
  Alcotest.(check int) "reservation closed" 0 (List.length p.reservations)

let test_commit_fill_removes_reservation () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:3 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:(d 0.01) ~fee_rate:(d 0.001)
      ~margin_policy:stub_policy
  in
  let p =
    Portfolio.commit_fill p ~id:3 ~actual_quantity:(d 10.0) ~actual_price:(d 99.5)
      ~actual_fee:(d 0.995)
  in
  Alcotest.(check (float 1e-3))
    "cash debited at actual" 9004.005 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-3))
    "available = cash again" (Decimal.to_float p.cash)
    (Decimal.to_float (Portfolio.available_cash p));
  Alcotest.(check int) "no reservations left" 0 (List.length p.reservations)

let test_release_removes_reservation_without_touching_cash () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:4 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:(d 0.01) ~fee_rate:(d 0.001)
      ~margin_policy:stub_policy
  in
  let p = Portfolio.release p ~id:4 in
  Alcotest.(check (float 1e-6)) "cash untouched" 10_000.0 (Decimal.to_float p.cash);
  Alcotest.(check int) "reservation gone" 0 (List.length p.reservations);
  Alcotest.(check (float 1e-6))
    "available = cash" 10_000.0
    (Decimal.to_float (Portfolio.available_cash p))

let test_commit_unknown_id_raises () =
  let p = Portfolio.empty ~cash:(d 1000.0) in
  Alcotest.check_raises "commit unknown id" Not_found (fun () ->
      let _ =
        Portfolio.commit_fill p ~id:42 ~actual_quantity:(d 1.0) ~actual_price:(d 1.0)
          ~actual_fee:Decimal.zero
      in
      ())

let test_commit_partial_fill_shrinks_reservation () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:10 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  Alcotest.(check (float 1e-6))
    "available after reserve" 9000.0
    (Decimal.to_float (Portfolio.available_cash p));
  let p =
    Portfolio.commit_partial_fill p ~id:10 ~actual_quantity:(d 3.0)
      ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
  in
  Alcotest.(check (float 1e-6)) "cash after partial" 9700.0 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-6))
    "available after partial" 9000.0
    (Decimal.to_float (Portfolio.available_cash p));
  Alcotest.(check int) "reservation still open" 1 (List.length p.reservations);
  let p =
    Portfolio.commit_partial_fill p ~id:10 ~actual_quantity:(d 7.0)
      ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
  in
  Alcotest.(check (float 1e-6)) "cash after full fill" 9000.0 (Decimal.to_float p.cash);
  Alcotest.(check int)
    "reservation closed on zero remaining" 0 (List.length p.reservations)

let test_commit_partial_fill_over_reserve_raises () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:11 ~side:Buy ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  Alcotest.check_raises "overfill raises"
    (Invalid_argument
       "Portfolio.commit_partial_fill: actual_quantity exceeds remaining reserved \
        quantity") (fun () ->
      let _ =
        Portfolio.commit_partial_fill p ~id:11 ~actual_quantity:(d 10.0)
          ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
      in
      ())

let test_multiple_reservations_stack () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:5 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  let p =
    Portfolio.reserve p ~id:6 ~side:Buy ~instrument:inst ~quantity:(d 20.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  Alcotest.(check (float 1e-6))
    "available reduced by both" 7000.0
    (Decimal.to_float (Portfolio.available_cash p))

let tests =
  [
    ("buy decreases cash", `Quick, test_buy_decreases_cash);
    ("partial close PnL", `Quick, test_partial_close_realizes_pnl);
    ("equity MTM", `Quick, test_equity_mark_to_market);
    ("flip long->short", `Quick, test_flip_from_long_to_short);
    ("reserve buy reduces available cash", `Quick, test_reserve_buy_reduces_available_cash);
    ("reserve sell cover-only", `Quick, test_reserve_sell_cover_only);
    ( "reserve sell open-only passes margin",
      `Quick,
      test_reserve_sell_open_only_passes_margin );
    ( "reserve sell open-only fails margin",
      `Quick,
      test_reserve_sell_open_only_fails_margin );
    ("reserve sell mixed cover+open", `Quick, test_reserve_sell_mixed_cover_and_open);
    ("reserve sell growing short", `Quick, test_reserve_sell_growing_short);
    ("commit partial fill cover-first", `Quick, test_commit_partial_fill_cover_first);
    ("commit_fill removes reservation", `Quick, test_commit_fill_removes_reservation);
    ( "release does not touch cash",
      `Quick,
      test_release_removes_reservation_without_touching_cash );
    ("commit unknown id raises", `Quick, test_commit_unknown_id_raises);
    ("multiple reservations stack", `Quick, test_multiple_reservations_stack);
    ( "partial fill shrinks reservation",
      `Quick,
      test_commit_partial_fill_shrinks_reservation );
    ("overfill on partial raises", `Quick, test_commit_partial_fill_over_reserve_raises);
  ]

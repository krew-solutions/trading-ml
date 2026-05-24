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

let test_commit_fill_cover_first_sell () =
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
    match
      Portfolio.commit_fill p ~id:1 ~actual_quantity:(d 5.0) ~actual_price:(d 100.0)
        ~actual_fee:Decimal.zero
    with
    | Ok (p', Portfolio.Drawn_down ev) ->
        Alcotest.check dec "drawn_quantity" (d 5.0) ev.drawn_quantity;
        Alcotest.check dec "remaining_cover_qty after first draw" (d 1.0)
          ev.remaining_cover_qty;
        Alcotest.check dec "remaining_open_qty unchanged" (d 4.0) ev.remaining_open_qty;
        p'
    | _ -> Alcotest.fail "expected Ok (Drawn_down _) on partial cover-first fill"
  in
  (match p.reservations with
  | [ r ] ->
      Alcotest.check dec "cover_qty after first partial" (d 1.0) r.cover_qty;
      Alcotest.check dec "open_qty unchanged after first partial" (d 4.0) r.open_qty
  | _ -> Alcotest.fail "expected one reservation");
  let p =
    match
      Portfolio.commit_fill p ~id:1 ~actual_quantity:(d 5.0) ~actual_price:(d 100.0)
        ~actual_fee:Decimal.zero
    with
    | Ok (p', Portfolio.Fully_committed _) -> p'
    | _ -> Alcotest.fail "expected Ok (Fully_committed _) on terminal fill"
  in
  Alcotest.(check int) "reservation closed" 0 (List.length p.reservations)

let test_commit_fill_removes_reservation () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:3 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:(d 0.01) ~fee_rate:(d 0.001)
      ~margin_policy:stub_policy
  in
  let p, event =
    match
      Portfolio.commit_fill p ~id:3 ~actual_quantity:(d 10.0) ~actual_price:(d 99.5)
        ~actual_fee:(d 0.995)
    with
    | Ok (p', Portfolio.Fully_committed ev) -> (p', ev)
    | _ -> Alcotest.fail "expected Ok (Fully_committed _)"
  in
  Alcotest.(check (float 1e-3))
    "cash debited at actual" 9004.005 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-3))
    "available = cash again" (Decimal.to_float p.cash)
    (Decimal.to_float (Portfolio.available_cash p));
  Alcotest.(check int) "no reservations left" 0 (List.length p.reservations);
  Alcotest.(check int) "event reservation_id" 3 event.reservation_id;
  Alcotest.(check (float 1e-3))
    "event filled_quantity" 10.0
    (Decimal.to_float event.filled_quantity);
  Alcotest.(check (float 1e-3))
    "event fill_price" 99.5
    (Decimal.to_float event.fill_price);
  Alcotest.(check (float 1e-3))
    "event new_cash" 9004.005
    (Decimal.to_float event.new_cash)

let test_release_removes_reservation_without_touching_cash () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:4 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:(d 0.01) ~fee_rate:(d 0.001)
      ~margin_policy:stub_policy
  in
  let p =
    match Portfolio.release p ~id:4 with
    | Ok (p', _event) -> p'
    | Error _ -> Alcotest.fail "expected the reservation to exist"
  in
  Alcotest.(check (float 1e-6)) "cash untouched" 10_000.0 (Decimal.to_float p.cash);
  Alcotest.(check int) "reservation gone" 0 (List.length p.reservations);
  Alcotest.(check (float 1e-6))
    "available = cash" 10_000.0
    (Decimal.to_float (Portfolio.available_cash p))

let test_commit_unknown_id_returns_not_found () =
  let p = Portfolio.empty ~cash:(d 1000.0) in
  match
    Portfolio.commit_fill p ~id:42 ~actual_quantity:(d 1.0) ~actual_price:(d 1.0)
      ~actual_fee:Decimal.zero
  with
  | Error (Portfolio.Reservation_not_found 42) -> ()
  | _ -> Alcotest.fail "expected Reservation_not_found 42"

let test_commit_fill_partial_buy_drawn_down () =
  (* reserve 10 Buy at 100, slippage 0, fee 0; commit 3 →
     Drawn_down with remaining_open_qty = 7, cash debited by 300,
     remaining reserved cash = 700, reservation still in the
     ledger. *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:10 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  Alcotest.(check (float 1e-6))
    "available after reserve" 9000.0
    (Decimal.to_float (Portfolio.available_cash p));
  match
    Portfolio.commit_fill p ~id:10 ~actual_quantity:(d 3.0) ~actual_price:(d 100.0)
      ~actual_fee:Decimal.zero
  with
  | Ok (p', Portfolio.Drawn_down ev) ->
      Alcotest.(check (float 1e-6)) "cash after partial" 9700.0 (Decimal.to_float p'.cash);
      Alcotest.(check (float 1e-6))
        "available after partial" 9000.0
        (Decimal.to_float (Portfolio.available_cash p'));
      Alcotest.(check int) "reservation still open" 1 (List.length p'.reservations);
      Alcotest.check dec "event remaining_open_qty" (d 7.0) ev.remaining_open_qty;
      Alcotest.check dec "event remaining_reserved_cash" (d 700.0)
        ev.remaining_reserved_cash;
      Alcotest.(check (float 1e-6)) "event new_cash" 9700.0 (Decimal.to_float ev.new_cash)
  | _ -> Alcotest.fail "expected Ok (Drawn_down _)"

let test_commit_fill_drawn_then_filled () =
  (* reserve 10 Buy at 100; commit 3, then commit 7 → first leg
     Drawn_down (open=7), second leg Fully_committed (reservation
     gone, cash = 9000). *)
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:20 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  let p =
    match
      Portfolio.commit_fill p ~id:20 ~actual_quantity:(d 3.0) ~actual_price:(d 100.0)
        ~actual_fee:Decimal.zero
    with
    | Ok (p', Portfolio.Drawn_down _) -> p'
    | _ -> Alcotest.fail "expected Drawn_down on first leg"
  in
  match
    Portfolio.commit_fill p ~id:20 ~actual_quantity:(d 7.0) ~actual_price:(d 100.0)
      ~actual_fee:Decimal.zero
  with
  | Ok (p', Portfolio.Fully_committed ev) ->
      Alcotest.(check (float 1e-6)) "cash after full" 9000.0 (Decimal.to_float p'.cash);
      Alcotest.(check int) "reservation closed" 0 (List.length p'.reservations);
      Alcotest.(check (float 1e-6))
        "event filled_quantity (terminal leg only)" 7.0
        (Decimal.to_float ev.filled_quantity)
  | _ -> Alcotest.fail "expected Fully_committed on second leg"

let test_commit_fill_overfill_returns_error () =
  let p = Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Portfolio.reserve p ~id:11 ~side:Buy ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:Decimal.zero ~fee_rate:Decimal.zero
      ~margin_policy:stub_policy
  in
  let cash_before = p.cash in
  let reservations_before = List.length p.reservations in
  match
    Portfolio.commit_fill p ~id:11 ~actual_quantity:(d 10.0) ~actual_price:(d 100.0)
      ~actual_fee:Decimal.zero
  with
  | Error (Portfolio.Overfill { id; attempted; remaining }) ->
      Alcotest.(check int) "overfill id" 11 id;
      Alcotest.check dec "overfill attempted" (d 10.0) attempted;
      Alcotest.check dec "overfill remaining" (d 5.0) remaining;
      Alcotest.check dec "portfolio cash unchanged" cash_before p.cash;
      Alcotest.(check int)
        "reservation count unchanged" reservations_before (List.length p.reservations)
  | _ -> Alcotest.fail "expected Error (Overfill _)"

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
    ("commit fill cover-first sell", `Quick, test_commit_fill_cover_first_sell);
    ("commit_fill removes reservation", `Quick, test_commit_fill_removes_reservation);
    ( "release does not touch cash",
      `Quick,
      test_release_removes_reservation_without_touching_cash );
    ( "commit unknown id returns Reservation_not_found",
      `Quick,
      test_commit_unknown_id_returns_not_found );
    ("multiple reservations stack", `Quick, test_multiple_reservations_stack);
    ( "commit_fill partial buy is Drawn_down",
      `Quick,
      test_commit_fill_partial_buy_drawn_down );
    ("commit_fill drawn then filled", `Quick, test_commit_fill_drawn_then_filled);
    ("commit_fill overfill returns Error", `Quick, test_commit_fill_overfill_returns_error);
  ]

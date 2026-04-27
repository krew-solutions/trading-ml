open Core

let d = Decimal.of_float
let dec =
  Alcotest.testable
    (fun fmt x -> Format.fprintf fmt "%s" (Decimal.to_string x))
    Decimal.equal

let inst =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

let test_buy_decreases_cash () =
  let p = Account.Portfolio.empty ~cash:(d 1000.0) in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 50.0)
      ~fee:(d 1.0)
  in
  Alcotest.(check bool) "cash decreased" true (Decimal.compare p.cash (d 499.0) = 0);
  match Account.Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "qty" (d 10.0) pos.quantity;
      Alcotest.check dec "avg" (d 50.0) pos.avg_price
  | None -> Alcotest.fail "no position"

let test_partial_close_realizes_pnl () =
  let p = Account.Portfolio.empty ~cash:(d 10000.0) in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Sell ~quantity:(d 5.0) ~price:(d 120.0)
      ~fee:Decimal.zero
  in
  Alcotest.check dec "realized 5*(120-100)=100" (d 100.0) p.realized_pnl;
  match Account.Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "remaining qty" (d 5.0) pos.quantity;
      Alcotest.check dec "avg unchanged" (d 100.0) pos.avg_price
  | None -> Alcotest.fail "missing"

let test_equity_mark_to_market () =
  let p = Account.Portfolio.empty ~cash:(d 1000.0) in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 10.0) ~price:(d 50.0)
      ~fee:Decimal.zero
  in
  let mark i = if Instrument.equal i inst then Some (d 55.0) else None in
  (* cash: 1000 - 500 = 500; position MTM: 10 * 55 = 550; total 1050 *)
  Alcotest.check dec "equity" (d 1050.0) (Account.Portfolio.equity p mark)

let test_flip_from_long_to_short () =
  let p = Account.Portfolio.empty ~cash:(d 10000.0) in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 5.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Sell ~quantity:(d 8.0) ~price:(d 110.0)
      ~fee:Decimal.zero
  in
  (* closes 5 long (realized: 5*10 = 50), remaining 3 short at 110 *)
  Alcotest.check dec "realized" (d 50.0) p.realized_pnl;
  match Account.Portfolio.position p inst with
  | Some pos ->
      Alcotest.check dec "new qty -3" (d (-3.0)) pos.quantity;
      Alcotest.check dec "new avg = 110" (d 110.0) pos.avg_price
  | None -> Alcotest.fail "missing"

(* --- Reservations --- *)

let test_reserve_buy_reduces_available_cash () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:1 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:0.01 (* 1% — reserve qty*price*1.01 *)
      ~fee_rate:0.001 (* 0.1% fee estimate *)
  in
  Alcotest.(check bool) "cash unchanged" true (Decimal.compare p.cash (d 10_000.0) = 0);
  (* reserved = 10 * 100 * 1.01 = 1010, fee = 10 * 100 * 0.001 = 1,
     total 1011. Available = 10000 - 1011 = 8989. *)
  Alcotest.(check (float 1e-3))
    "available cash" 8989.0
    (Decimal.to_float (Account.Portfolio.available_cash p))

let test_reserve_sell_does_not_touch_cash () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.fill p ~instrument:inst ~side:Buy ~quantity:(d 20.0) ~price:(d 100.0)
      ~fee:Decimal.zero
  in
  let p =
    Account.Portfolio.reserve p ~id:2 ~side:Sell ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:0.0 ~fee_rate:0.0
  in
  Alcotest.(check (float 1e-6)) "cash unchanged" 8000.0 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-6))
    "available_cash unchanged for sells" 8000.0
    (Decimal.to_float (Account.Portfolio.available_cash p));
  Alcotest.(check (float 1e-6))
    "available_qty dropped" 15.0
    (Decimal.to_float (Account.Portfolio.available_qty p inst))

let test_commit_fill_removes_reservation () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:3 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:0.01 ~fee_rate:0.001
  in
  (* Commit with actual numbers slightly different from reservation. *)
  let p =
    Account.Portfolio.commit_fill p ~id:3 ~actual_quantity:(d 10.0) ~actual_price:(d 99.5)
      ~actual_fee:(d 0.995)
  in
  (* Reservation gone, available_cash = cash = 10000 - 995 - 0.995 *)
  Alcotest.(check (float 1e-3))
    "cash debited at actual" 9004.005 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-3))
    "available = cash again" (Decimal.to_float p.cash)
    (Decimal.to_float (Account.Portfolio.available_cash p));
  Alcotest.(check int) "no reservations left" 0 (List.length p.reservations)

let test_release_removes_reservation_without_touching_cash () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:4 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:0.01 ~fee_rate:0.001
  in
  let p = Account.Portfolio.release p ~id:4 in
  Alcotest.(check (float 1e-6)) "cash untouched" 10_000.0 (Decimal.to_float p.cash);
  Alcotest.(check int) "reservation gone" 0 (List.length p.reservations);
  Alcotest.(check (float 1e-6))
    "available = cash" 10_000.0
    (Decimal.to_float (Account.Portfolio.available_cash p))

let test_commit_unknown_id_raises () =
  let p = Account.Portfolio.empty ~cash:(d 1000.0) in
  Alcotest.check_raises "commit unknown id" Not_found (fun () ->
      let _ =
        Account.Portfolio.commit_fill p ~id:42 ~actual_quantity:(d 1.0)
          ~actual_price:(d 1.0) ~actual_fee:Decimal.zero
      in
      ())

let test_commit_partial_fill_shrinks_reservation () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:10 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:0.0 ~fee_rate:0.0
  in
  (* Available_cash = 10000 - 10 * 100 = 9000. *)
  Alcotest.(check (float 1e-6))
    "available after reserve" 9000.0
    (Decimal.to_float (Account.Portfolio.available_cash p));
  (* Commit partial: 3 shares @ 100. *)
  let p =
    Account.Portfolio.commit_partial_fill p ~id:10 ~actual_quantity:(d 3.0)
      ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
  in
  (* Portfolio cash: -300 (3 shares × 100). Remaining reservation
     7 shares × 100 = 700. Available = 9700 - 700 = 9000... wait.
     Actually: cash = 10000 - 300 = 9700. Reservation shrinks to
     quantity=7, per_unit_cash=100. reserved_cash = 700.
     available_cash = 9700 - 700 = 9000. Unchanged. That's correct —
     the fill moved cash into a position but didn't change "what's
     available to spend". *)
  Alcotest.(check (float 1e-6)) "cash after partial" 9700.0 (Decimal.to_float p.cash);
  Alcotest.(check (float 1e-6))
    "available after partial" 9000.0
    (Decimal.to_float (Account.Portfolio.available_cash p));
  Alcotest.(check int) "reservation still open" 1 (List.length p.reservations);
  (* Commit remaining 7 @ 100. *)
  let p =
    Account.Portfolio.commit_partial_fill p ~id:10 ~actual_quantity:(d 7.0)
      ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
  in
  Alcotest.(check (float 1e-6)) "cash after full fill" 9000.0 (Decimal.to_float p.cash);
  Alcotest.(check int)
    "reservation closed on zero remaining" 0 (List.length p.reservations)

let test_commit_partial_fill_over_reserve_raises () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:11 ~side:Buy ~instrument:inst ~quantity:(d 5.0)
      ~price:(d 100.0) ~slippage_buffer:0.0 ~fee_rate:0.0
  in
  Alcotest.check_raises "overfill raises"
    (Invalid_argument
       "Portfolio.commit_partial_fill: actual_quantity exceeds remaining reserved \
        quantity") (fun () ->
      let _ =
        Account.Portfolio.commit_partial_fill p ~id:11 ~actual_quantity:(d 10.0)
          ~actual_price:(d 100.0) ~actual_fee:Decimal.zero
      in
      ())

let test_multiple_reservations_stack () =
  let p = Account.Portfolio.empty ~cash:(d 10_000.0) in
  let p =
    Account.Portfolio.reserve p ~id:5 ~side:Buy ~instrument:inst ~quantity:(d 10.0)
      ~price:(d 100.0) ~slippage_buffer:0.0 ~fee_rate:0.0
  in
  let p =
    Account.Portfolio.reserve p ~id:6 ~side:Buy ~instrument:inst ~quantity:(d 20.0)
      ~price:(d 100.0) ~slippage_buffer:0.0 ~fee_rate:0.0
  in
  (* total reserved: 1000 + 2000 = 3000 *)
  Alcotest.(check (float 1e-6))
    "available reduced by both" 7000.0
    (Decimal.to_float (Account.Portfolio.available_cash p))

let tests =
  [
    ("buy decreases cash", `Quick, test_buy_decreases_cash);
    ("partial close PnL", `Quick, test_partial_close_realizes_pnl);
    ("equity MTM", `Quick, test_equity_mark_to_market);
    ("flip long->short", `Quick, test_flip_from_long_to_short);
    ("reserve buy reduces available cash", `Quick, test_reserve_buy_reduces_available_cash);
    ("reserve sell does not touch cash", `Quick, test_reserve_sell_does_not_touch_cash);
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

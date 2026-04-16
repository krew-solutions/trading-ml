open Core

let d = Decimal.of_float
let dec = Alcotest.testable
  (fun fmt x -> Format.fprintf fmt "%s" (Decimal.to_string x))
  Decimal.equal

let sym = Symbol.of_string "SBER"

let test_buy_decreases_cash () =
  let p = Engine.Portfolio.empty ~cash:(d 1000.0) in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Buy
    ~quantity:(d 10.0) ~price:(d 50.0) ~fee:(d 1.0)
  in
  Alcotest.(check bool) "cash decreased" true
    (Decimal.compare p.cash (d 499.0) = 0);
  match Engine.Portfolio.position p sym with
  | Some pos ->
    Alcotest.check dec "qty" (d 10.0) pos.quantity;
    Alcotest.check dec "avg" (d 50.0) pos.avg_price
  | None -> Alcotest.fail "no position"

let test_partial_close_realizes_pnl () =
  let p = Engine.Portfolio.empty ~cash:(d 10000.0) in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Buy ~quantity:(d 10.0)
    ~price:(d 100.0) ~fee:Decimal.zero
  in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Sell ~quantity:(d 5.0)
    ~price:(d 120.0) ~fee:Decimal.zero
  in
  Alcotest.check dec "realized 5*(120-100)=100" (d 100.0) p.realized_pnl;
  match Engine.Portfolio.position p sym with
  | Some pos ->
    Alcotest.check dec "remaining qty" (d 5.0) pos.quantity;
    Alcotest.check dec "avg unchanged" (d 100.0) pos.avg_price
  | None -> Alcotest.fail "missing"

let test_equity_mark_to_market () =
  let p = Engine.Portfolio.empty ~cash:(d 1000.0) in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Buy ~quantity:(d 10.0)
    ~price:(d 50.0) ~fee:Decimal.zero
  in
  let mark s = if Symbol.equal s sym then Some (d 55.0) else None in
  (* cash: 1000 - 500 = 500; position MTM: 10 * 55 = 550; total 1050 *)
  Alcotest.check dec "equity" (d 1050.0) (Engine.Portfolio.equity p mark)

let test_flip_from_long_to_short () =
  let p = Engine.Portfolio.empty ~cash:(d 10000.0) in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Buy ~quantity:(d 5.0)
    ~price:(d 100.0) ~fee:Decimal.zero
  in
  let p = Engine.Portfolio.fill p
    ~symbol:sym ~side:Sell ~quantity:(d 8.0)
    ~price:(d 110.0) ~fee:Decimal.zero
  in
  (* closes 5 long (realized: 5*10 = 50), remaining 3 short at 110 *)
  Alcotest.check dec "realized" (d 50.0) p.realized_pnl;
  match Engine.Portfolio.position p sym with
  | Some pos ->
    Alcotest.check dec "new qty -3" (d (-3.0)) pos.quantity;
    Alcotest.check dec "new avg = 110" (d 110.0) pos.avg_price
  | None -> Alcotest.fail "missing"

let tests = [
  "buy decreases cash", `Quick, test_buy_decreases_cash;
  "partial close PnL", `Quick, test_partial_close_realizes_pnl;
  "equity MTM", `Quick, test_equity_mark_to_market;
  "flip long->short", `Quick, test_flip_from_long_to_short;
]

open Core

let d = Decimal.of_float
let d_int = Decimal.of_int

let mk_instrument ticker = Instrument.make
  ~ticker:(Ticker.of_string ticker)
  ~venue:(Mic.of_string "MISX") ()

(** Minimal stub broker — Paper never routes orders through its
    source, and these tests feed bars via [on_bar] directly, so
    delegate methods are never exercised in the happy paths. *)
let mk_source () : Broker.client =
  let module M = struct
    type t = unit
    let name = "mock-source"
    let bars () ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues () = []
    let place_order () ~instrument:_ ~side:_ ~quantity:_
        ~kind:_ ~tif:_ ~client_order_id:_ = failwith "n/a"
    let get_orders () = failwith "n/a"
    let get_order () ~client_order_id:_ = failwith "n/a"
    let cancel_order () ~client_order_id:_ = failwith "n/a"
  end in
  Broker.make (module M) ()

let bar ~ts ~o ~h ~l ~c =
  Candle.make
    ~ts:(Int64.of_int ts)
    ~open_:(d o) ~high:(d h) ~low:(d l) ~close:(d c)
    ~volume:(d_int 1)

let decimal_testable =
  Alcotest.testable (fun fmt x -> Format.fprintf fmt "%s" (Decimal.to_string x))
    Decimal.equal

let status_testable =
  Alcotest.testable
    (fun fmt s -> Format.fprintf fmt "%s" (Order.status_to_string s))
    (=)

let test_market_fills_at_next_open () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  (* Seed the decorator with one bar so placed_after_ts is non-zero. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let order =
    Paper.Paper_broker.place_order p
      ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY
      ~client_order_id:"cid-1"
  in
  Alcotest.(check status_testable) "new on place" Order.New order.status;
  (* Next bar arrives — market order fills at its open. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.5 ~h:102.0 ~l:100.5 ~c:101.0);
  let o = Paper.Paper_broker.get_order p ~client_order_id:"cid-1" in
  Alcotest.(check status_testable) "filled" Order.Filled o.status;
  Alcotest.(check decimal_testable) "filled qty" (d_int 10) o.filled;
  match Paper.Paper_broker.fills p with
  | [f] ->
    Alcotest.(check decimal_testable) "fill price = next open"
      (d 101.5) f.price
  | _ -> Alcotest.fail "expected exactly one fill"

let test_same_bar_does_not_fill () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:inst ~side:Buy ~quantity:(d_int 5)
    ~kind:Order.Market ~tif:Order.DAY
    ~client_order_id:"cid-2"
  in
  (* Re-feed the same bar — simulates WS sending an update for the
     bar that was already "current" at placement time. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.5 ~l:99.5 ~c:100.2);
  let o = Paper.Paper_broker.get_order p ~client_order_id:"cid-2" in
  Alcotest.(check status_testable) "still new" Order.New o.status

let test_limit_buy_fills_at_limit () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:105.0 ~h:105.0 ~l:105.0 ~c:105.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:inst ~side:Buy ~quantity:(d_int 1)
    ~kind:(Order.Limit (d 100.0)) ~tif:Order.DAY
    ~client_order_id:"cid-lim"
  in
  (* Bar's open (102) is above the limit, but low (99) touches it —
     fill at the limit. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:102.0 ~h:103.0 ~l:99.0 ~c:101.0);
  (match Paper.Paper_broker.fills p with
   | [f] -> Alcotest.(check decimal_testable) "fill at limit"
              (d 100.0) f.price
   | _ -> Alcotest.fail "expected one fill")

let test_limit_buy_gap_fills_at_open () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:105.0 ~h:105.0 ~l:105.0 ~c:105.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:inst ~side:Buy ~quantity:(d_int 1)
    ~kind:(Order.Limit (d 100.0)) ~tif:Order.DAY
    ~client_order_id:"cid-gap"
  in
  (* Gap-down open (95) is already below the limit — fill at open. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:95.0 ~h:96.0 ~l:94.0 ~c:95.5);
  match Paper.Paper_broker.fills p with
  | [f] -> Alcotest.(check decimal_testable) "fill at gap open"
             (d 95.0) f.price
  | _ -> Alcotest.fail "expected one fill"

let test_stop_sell_triggers_on_low () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:inst ~side:Sell ~quantity:(d_int 1)
    ~kind:(Order.Stop (d 95.0)) ~tif:Order.DAY
    ~client_order_id:"cid-stop"
  in
  (* Bar dips through the stop — fill at the stop. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:99.0 ~h:99.5 ~l:94.0 ~c:98.0);
  match Paper.Paper_broker.fills p with
  | [f] -> Alcotest.(check decimal_testable) "stop triggered"
             (d 95.0) f.price
  | _ -> Alcotest.fail "expected stop fill"

let test_cancel_prevents_fill () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:inst ~side:Buy ~quantity:(d_int 1)
    ~kind:Order.Market ~tif:Order.DAY
    ~client_order_id:"cid-cancel"
  in
  let cancelled = Paper.Paper_broker.cancel_order p ~client_order_id:"cid-cancel" in
  Alcotest.(check status_testable) "cancelled" Order.Cancelled cancelled.status;
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.0 ~h:102.0 ~l:100.0 ~c:101.5);
  Alcotest.(check int) "no fills after cancel" 0
    (List.length (Paper.Paper_broker.fills p))

let test_get_orders_returns_insertion_order () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  List.iter (fun cid ->
    let _ = Paper.Paper_broker.place_order p
      ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:cid
    in ()) ["a"; "b"; "c"];
  let orders = Paper.Paper_broker.get_orders p in
  Alcotest.(check (list string)) "chronological"
    ["a"; "b"; "c"]
    (List.map (fun (o : Order.t) -> o.client_order_id) orders)

let test_cross_instrument_isolation () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let a = mk_instrument "SBER" in
  let b = mk_instrument "GAZP" in
  Paper.Paper_broker.on_bar p ~instrument:a
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ = Paper.Paper_broker.place_order p
    ~instrument:a ~side:Buy ~quantity:(d_int 1)
    ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-a"
  in
  (* Bar on a different instrument — must not fill the SBER order. *)
  Paper.Paper_broker.on_bar p ~instrument:b
    (bar ~ts:200 ~o:50.0 ~h:51.0 ~l:49.0 ~c:50.5);
  Alcotest.(check int) "no cross-instrument fill" 0
    (List.length (Paper.Paper_broker.fills p))

let tests = [
  "market fills at next open",   `Quick, test_market_fills_at_next_open;
  "same bar does not fill",      `Quick, test_same_bar_does_not_fill;
  "limit buy fills at limit",    `Quick, test_limit_buy_fills_at_limit;
  "limit buy gap fills at open", `Quick, test_limit_buy_gap_fills_at_open;
  "stop sell triggers on low",   `Quick, test_stop_sell_triggers_on_low;
  "cancel prevents fill",        `Quick, test_cancel_prevents_fill;
  "get_orders chronological",    `Quick, test_get_orders_returns_insertion_order;
  "cross-instrument isolation",  `Quick, test_cross_instrument_isolation;
]

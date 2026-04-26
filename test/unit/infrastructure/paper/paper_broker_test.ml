open Core

let d = Decimal.of_float
let d_int = Decimal.of_int

let mk_instrument ticker =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string "MISX") ()

(** Minimal stub broker — Paper never routes orders through its
    source, and these tests feed bars via [on_bar] directly, so
    delegate methods are never exercised in the happy paths. *)
let mk_source () : Broker.client =
  let module M = struct
    type t = unit
    let name = "mock-source"
    let bars () ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues () = []
    let place_order () ~instrument:_ ~side:_ ~quantity:_ ~kind:_ ~tif:_ ~client_order_id:_
        =
      failwith "n/a"
    let get_orders () = failwith "n/a"
    let get_order () ~client_order_id:_ = failwith "n/a"
    let cancel_order () ~client_order_id:_ = failwith "n/a"
    let get_executions () ~client_order_id:_ = []
    let generate_client_order_id =
      let n = ref 0 in
      fun _ ->
        incr n;
        Printf.sprintf "test-cid-%d" !n
  end in
  Broker.make (module M) ()

let bar ~ts ~o ~h ~l ~c =
  Candle.make ~ts:(Int64.of_int ts) ~open_:(d o) ~high:(d h) ~low:(d l) ~close:(d c)
    ~volume:(d_int 1)

let decimal_testable =
  Alcotest.testable
    (fun fmt x -> Format.fprintf fmt "%s" (Decimal.to_string x))
    Decimal.equal

let status_testable =
  Alcotest.testable
    (fun fmt s -> Format.fprintf fmt "%s" (Order.status_to_string s))
    ( = )

let test_market_fills_at_next_open () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  (* Seed the decorator with one bar so placed_after_ts is non-zero. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let order =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-1"
  in
  Alcotest.(check status_testable) "new on place" Order.New order.status;
  (* Next bar arrives — market order fills at its open. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.5 ~h:102.0 ~l:100.5 ~c:101.0);
  let o = Paper.Paper_broker.get_order p ~client_order_id:"cid-1" in
  Alcotest.(check status_testable) "filled" Order.Filled o.status;
  Alcotest.(check decimal_testable) "filled qty" (d_int 10) o.filled;
  match Paper.Paper_broker.fills p with
  | [ f ] -> Alcotest.(check decimal_testable) "fill price = next open" (d 101.5) f.price
  | _ -> Alcotest.fail "expected exactly one fill"

let test_same_bar_does_not_fill () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 5)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-2"
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
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:(Order.Limit (d 100.0))
      ~tif:Order.DAY ~client_order_id:"cid-lim"
  in
  (* Bar's open (102) is above the limit, but low (99) touches it —
     fill at the limit. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:102.0 ~h:103.0 ~l:99.0 ~c:101.0);
  match Paper.Paper_broker.fills p with
  | [ f ] -> Alcotest.(check decimal_testable) "fill at limit" (d 100.0) f.price
  | _ -> Alcotest.fail "expected one fill"

let test_limit_buy_gap_fills_at_open () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:105.0 ~h:105.0 ~l:105.0 ~c:105.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:(Order.Limit (d 100.0))
      ~tif:Order.DAY ~client_order_id:"cid-gap"
  in
  (* Gap-down open (95) is already below the limit — fill at open. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:95.0 ~h:96.0 ~l:94.0 ~c:95.5);
  match Paper.Paper_broker.fills p with
  | [ f ] -> Alcotest.(check decimal_testable) "fill at gap open" (d 95.0) f.price
  | _ -> Alcotest.fail "expected one fill"

let test_stop_sell_triggers_on_low () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Sell ~quantity:(d_int 1)
      ~kind:(Order.Stop (d 95.0))
      ~tif:Order.DAY ~client_order_id:"cid-stop"
  in
  (* Bar dips through the stop — fill at the stop. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:99.0 ~h:99.5 ~l:94.0 ~c:98.0);
  match Paper.Paper_broker.fills p with
  | [ f ] -> Alcotest.(check decimal_testable) "stop triggered" (d 95.0) f.price
  | _ -> Alcotest.fail "expected stop fill"

let test_cancel_prevents_fill () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-cancel"
  in
  let cancelled = Paper.Paper_broker.cancel_order p ~client_order_id:"cid-cancel" in
  Alcotest.(check status_testable) "cancelled" Order.Cancelled cancelled.status;
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.0 ~h:102.0 ~l:100.0 ~c:101.5);
  Alcotest.(check int)
    "no fills after cancel" 0
    (List.length (Paper.Paper_broker.fills p))

let test_get_orders_returns_insertion_order () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  List.iter
    (fun cid ->
      let _ =
        Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
          ~kind:Order.Market ~tif:Order.DAY ~client_order_id:cid
      in
      ())
    [ "a"; "b"; "c" ];
  let orders = Paper.Paper_broker.get_orders p in
  Alcotest.(check (list string))
    "chronological" [ "a"; "b"; "c" ]
    (List.map (fun (o : Order.t) -> o.client_order_id) orders)

let test_cross_instrument_isolation () =
  let p = Paper.Paper_broker.make ~source:(mk_source ()) () in
  let a = mk_instrument "SBER" in
  let b = mk_instrument "GAZP" in
  Paper.Paper_broker.on_bar p ~instrument:a
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:a ~side:Buy ~quantity:(d_int 1)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-a"
  in
  (* Bar on a different instrument — must not fill the SBER order. *)
  Paper.Paper_broker.on_bar p ~instrument:b (bar ~ts:200 ~o:50.0 ~h:51.0 ~l:49.0 ~c:50.5);
  Alcotest.(check int)
    "no cross-instrument fill" 0
    (List.length (Paper.Paper_broker.fills p))

let test_portfolio_updates_on_fill () =
  let p =
    Paper.Paper_broker.make ~initial_cash:(d_int 100_000) ~source:(mk_source ()) ()
  in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-pf"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.0 ~h:102.0 ~l:100.5 ~c:101.5);
  let pf = Paper.Paper_broker.portfolio p in
  Alcotest.(check (option (pair string decimal_testable)))
    "position 10 @ 101 after buy"
    (Some ("SBER", d 101.0))
    (Option.map
       (fun (pos : Engine.Portfolio.position) ->
         (Ticker.to_string (Instrument.ticker pos.instrument), pos.avg_price))
       (Engine.Portfolio.position pf inst));
  let expected_cash = Decimal.sub (d_int 100_000) (Decimal.mul (d_int 10) (d 101.0)) in
  Alcotest.(check decimal_testable) "cash debited" expected_cash pf.cash

let bar_v ~ts ~o ~h ~l ~c ~v =
  Candle.make ~ts:(Int64.of_int ts) ~open_:(d o) ~high:(d h) ~low:(d l) ~close:(d c)
    ~volume:(d_int v)

let test_fee_charged_on_fill () =
  let p =
    Paper.Paper_broker.make ~initial_cash:(d_int 100_000)
      ~fee_rate:0.0005 (* 5 bps, mirrors backtest default *)
      ~source:(mk_source ()) ()
  in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-fee"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:101.0 ~h:101.0 ~l:101.0 ~c:101.0);
  match Paper.Paper_broker.fills p with
  | [ f ] ->
      (* fee = qty * price * rate = 10 * 101 * 0.0005 = 0.505 *)
      Alcotest.(check (float 1e-4)) "fee charged" 0.505 (Decimal.to_float f.fee)
  | _ -> Alcotest.fail "expected one fill"

let test_slippage_market_buy_pays_premium () =
  let p =
    Paper.Paper_broker.make ~slippage_bps:10.0 (* 10 bps *) ~source:(mk_source ()) ()
  in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-slip-buy"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  match Paper.Paper_broker.fills p with
  | [ f ] ->
      Alcotest.(check (float 1e-4)) "buy paid ~10 bps up" 100.1 (Decimal.to_float f.price)
  | _ -> Alcotest.fail "expected one fill"

let test_slippage_market_sell_receives_discount () =
  let p = Paper.Paper_broker.make ~slippage_bps:10.0 ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Sell ~quantity:(d_int 1)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-slip-sell"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0);
  match Paper.Paper_broker.fills p with
  | [ f ] ->
      Alcotest.(check (float 1e-4))
        "sell received ~10 bps less" 99.9 (Decimal.to_float f.price)
  | _ -> Alcotest.fail "expected one fill"

let test_slippage_does_not_apply_to_limit () =
  let p = Paper.Paper_broker.make ~slippage_bps:50.0 ~source:(mk_source ()) () in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:100 ~o:105.0 ~h:105.0 ~l:105.0 ~c:105.0);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 1)
      ~kind:(Order.Limit (d 100.0))
      ~tif:Order.DAY ~client_order_id:"cid-lim-noslip"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar ~ts:200 ~o:99.0 ~h:100.0 ~l:98.0 ~c:99.5);
  match Paper.Paper_broker.fills p with
  | [ f ] ->
      (* Bar opens at 99 — below 100 limit — fills at open, no slippage. *)
      Alcotest.(check decimal_testable) "limit fills at stated open" (d 99.0) f.price
  | _ -> Alcotest.fail "expected one fill"

let test_partial_fill_splits_across_bars () =
  let p =
    Paper.Paper_broker.make
      ~participation_rate:1.0 (* can consume 100% of each bar's volume *)
      ~source:(mk_source ()) ()
  in
  let inst = mk_instrument "SBER" in
  (* Seed first, then place a 10-qty order whose bars carry only 4
     volume each — should fill 4, 4, 2 across three bars. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:4);
  let order =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-partial"
  in
  Alcotest.(check status_testable) "new on place" Order.New order.status;
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:200 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:4);
  let s1 = Paper.Paper_broker.get_order p ~client_order_id:"cid-partial" in
  Alcotest.(check status_testable)
    "partial after first bar" Order.Partially_filled s1.status;
  Alcotest.(check decimal_testable) "4 filled" (d_int 4) s1.filled;
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:300 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:4);
  let s2 = Paper.Paper_broker.get_order p ~client_order_id:"cid-partial" in
  Alcotest.(check status_testable) "still partial" Order.Partially_filled s2.status;
  Alcotest.(check decimal_testable) "8 filled" (d_int 8) s2.filled;
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:400 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:4);
  let s3 = Paper.Paper_broker.get_order p ~client_order_id:"cid-partial" in
  Alcotest.(check status_testable) "filled after third bar" Order.Filled s3.status;
  Alcotest.(check decimal_testable) "10 filled" (d_int 10) s3.filled;
  Alcotest.(check int) "three fill records" 3 (List.length (Paper.Paper_broker.fills p))

let test_participation_rate_caps_per_bar () =
  let p =
    Paper.Paper_broker.make ~participation_rate:0.25 (* 25% of bar volume *)
      ~source:(mk_source ()) ()
  in
  let inst = mk_instrument "SBER" in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:100 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:100);
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 10)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-rate"
  in
  (* Bar volume 100, rate 0.25 → cap 25. Remaining 10 ≤ 25, so full fill. *)
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:200 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:100);
  let o = Paper.Paper_broker.get_order p ~client_order_id:"cid-rate" in
  Alcotest.(check status_testable) "full fill when cap exceeds qty" Order.Filled o.status;
  (* Different order: qty 50 against bar volume 100 — cap 25 → partial. *)
  let _ =
    Paper.Paper_broker.place_order p ~instrument:inst ~side:Buy ~quantity:(d_int 50)
      ~kind:Order.Market ~tif:Order.DAY ~client_order_id:"cid-rate-2"
  in
  Paper.Paper_broker.on_bar p ~instrument:inst
    (bar_v ~ts:300 ~o:100.0 ~h:100.0 ~l:100.0 ~c:100.0 ~v:100);
  let o2 = Paper.Paper_broker.get_order p ~client_order_id:"cid-rate-2" in
  Alcotest.(check status_testable)
    "partial when qty exceeds cap" Order.Partially_filled o2.status;
  Alcotest.(check decimal_testable) "25 filled = rate * volume" (d_int 25) o2.filled

let tests =
  [
    ("market fills at next open", `Quick, test_market_fills_at_next_open);
    ("same bar does not fill", `Quick, test_same_bar_does_not_fill);
    ("limit buy fills at limit", `Quick, test_limit_buy_fills_at_limit);
    ("limit buy gap fills at open", `Quick, test_limit_buy_gap_fills_at_open);
    ("stop sell triggers on low", `Quick, test_stop_sell_triggers_on_low);
    ("cancel prevents fill", `Quick, test_cancel_prevents_fill);
    ("get_orders chronological", `Quick, test_get_orders_returns_insertion_order);
    ("cross-instrument isolation", `Quick, test_cross_instrument_isolation);
    ("portfolio updates on fill", `Quick, test_portfolio_updates_on_fill);
    ("fee charged on fill", `Quick, test_fee_charged_on_fill);
    ("slippage buy pays premium", `Quick, test_slippage_market_buy_pays_premium);
    ("slippage sell discount", `Quick, test_slippage_market_sell_receives_discount);
    ("slippage skipped on limit", `Quick, test_slippage_does_not_apply_to_limit);
    ("partial fill across bars", `Quick, test_partial_fill_splits_across_bars);
    ("participation caps per bar", `Quick, test_participation_rate_caps_per_bar);
  ]

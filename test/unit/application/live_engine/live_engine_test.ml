open Core

let d = Decimal.of_float
let d_int = Decimal.of_int

let mk_instrument ticker = Instrument.make
  ~ticker:(Ticker.of_string ticker)
  ~venue:(Mic.of_string "MISX") ()

let bar ~ts ~px =
  Candle.make
    ~ts:(Int64.of_int ts)
    ~open_:(d px) ~high:(d px) ~low:(d px) ~close:(d px)
    ~volume:(d_int 1)

(** Mock broker that records every place_order call. *)
module Recording_broker = struct
  type record = {
    client_order_id : string;
    side : Side.t;
    quantity : Decimal.t;
    kind : Order.kind;
  }

  type t = {
    mutable placed : record list;
  }

  let create () = { placed = [] }
  let records t = List.rev t.placed
  let count t = List.length t.placed
end

let mk_broker (rec_ : Recording_broker.t) : Broker.client =
  let module M = struct
    type t = Recording_broker.t
    let name = "recording"
    let bars _ ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues _ = []
    let place_order rec_ ~instrument ~side ~quantity ~kind ~tif ~client_order_id =
      let open Recording_broker in
      rec_.placed <- { client_order_id; side; quantity; kind } :: rec_.placed;
      {
        Order.id = client_order_id;
        exec_id = "";
        instrument; side; quantity;
        filled = Decimal.zero;
        remaining = quantity;
        kind; tif;
        status = Order.New;
        created_ts = 0L;
        client_order_id;
      }
    let get_orders _ = []
    let get_order _ ~client_order_id:_ = failwith "n/a"
    let cancel_order _ ~client_order_id:_ = failwith "n/a"
  end in
  Broker.make (module M) rec_

(** Fixed-signal strategy: always emits the configured action with
    strength 0.5. Lets us drive the engine's translation logic
    directly, without depending on indicator behaviour. *)
module Fixed_signal_strategy = struct
  type params = { action : Signal.action }
  type state = { action : Signal.action }

  let name = "fixed"
  let default_params : params = { action = Signal.Hold }
  let init (p : params) : state = { action = p.action }

  let on_candle (s : state) (instrument : Instrument.t) (c : Candle.t)
    : state * Signal.t =
    s, {
      ts = c.Candle.ts;
      instrument;
      action = s.action;
      strength = 0.5;
      stop_loss = None;
      take_profit = None;
      reason = "fixed";
    }
end

let mk_engine ~broker ~action =
  let strat = Strategies.Strategy.make
    (module Fixed_signal_strategy) { action }
  in
  let equity = d_int 1_000_000 in
  let cfg : Live_engine.config = {
    broker;
    strategy = strat;
    instrument = mk_instrument "SBER";
    initial_cash = equity;
    limits = Engine.Risk.default_limits ~equity;
    tif = Order.DAY;
    fee_rate = 0.0;
  } in
  Live_engine.make cfg

(* Pending-signal semantics: a signal on bar T fires an order at bar
   T+1's open. Tests feed two bars — the first produces the signal,
   the second executes it. *)

let test_enter_long_places_buy () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Alcotest.(check int) "no order until next bar"
    0 (Recording_broker.count rec_);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  Alcotest.(check int) "one order placed" 1 (Recording_broker.count rec_);
  match Recording_broker.records rec_ with
  | [r] ->
    Alcotest.(check string) "side" "BUY" (Side.to_string r.side);
    Alcotest.(check bool) "positive qty" true (Decimal.is_positive r.quantity);
    Alcotest.(check bool) "market kind" true (r.kind = Order.Market)
  | _ -> Alcotest.fail "expected exactly one record"

let test_hold_places_nothing () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Hold in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  Alcotest.(check int) "no orders" 0 (Recording_broker.count rec_)

(** Time-based strategy: Enter_long on the first bar (ts=100),
    Exit_long on the second (ts=200), Hold elsewhere. Lets us drive
    a full enter-then-exit roundtrip through one engine instance. *)
module Scripted_strategy = struct
  type params = unit
  type state = unit
  let name = "scripted"
  let default_params = ()
  let init () = ()
  let on_candle () instrument c : state * Signal.t =
    let action : Signal.action =
      if Int64.equal c.Candle.ts 100L then Enter_long
      else if Int64.equal c.ts 200L then Exit_long
      else Hold
    in
    (), {
      ts = c.ts; instrument; action;
      strength = 0.5;
      stop_loss = None; take_profit = None;
      reason = "scripted";
    }
end

let test_enter_then_exit_roundtrip () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let strat = Strategies.Strategy.make (module Scripted_strategy) () in
  let equity = d_int 1_000_000 in
  let cfg : Live_engine.config = {
    broker; strategy = strat;
    instrument = mk_instrument "SBER";
    initial_cash = equity;
    limits = Engine.Risk.default_limits ~equity;
    tif = Order.DAY;
    fee_rate = 0.0;
  } in
  let e = Live_engine.make cfg in
  (* Bar 100: strategy emits Enter_long → queued; no order yet. *)
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Alcotest.(check int) "no order on signal bar"
    0 (Recording_broker.count rec_);
  (* Bar 200: pending Enter executes at open[200]; new signal Exit
     gets queued for next bar. *)
  Live_engine.on_bar e (bar ~ts:200 ~px:101.0);
  Alcotest.(check int) "one order after enter executes"
    1 (Recording_broker.count rec_);
  let qty = Live_engine.position e in
  Alcotest.(check bool) "long after enter" true (Decimal.is_positive qty);
  (* Bar 300: pending Exit executes. Strategy emits Hold, nothing queued. *)
  Live_engine.on_bar e (bar ~ts:300 ~px:102.0);
  Alcotest.(check int) "two orders after exit" 2 (Recording_broker.count rec_);
  Alcotest.(check bool) "flat after exit"
    true (Decimal.is_zero (Live_engine.position e));
  match Recording_broker.records rec_ with
  | [enter; exit_] ->
    Alcotest.(check string) "enter side" "BUY" (Side.to_string enter.side);
    Alcotest.(check string) "exit side" "SELL" (Side.to_string exit_.side);
    Alcotest.(check bool) "exit qty matches entry"
      true (Decimal.equal enter.quantity exit_.quantity)
  | _ -> Alcotest.fail "expected exactly two records"

let test_exit_long_when_flat_is_noop () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Exit_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  Alcotest.(check int) "no order from exit-when-flat"
    0 (Recording_broker.count rec_);
  Alcotest.(check bool) "position still zero"
    true (Decimal.is_zero (Live_engine.position e))

let test_out_of_order_bar_ignored () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);   (* queues Enter *)
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);   (* fires at open[200] *)
  let after_first = Recording_broker.count rec_ in
  Alcotest.(check int) "one order after two-bar warmup" 1 after_first;
  (* Feed an older bar — should be dropped, no second order. *)
  Live_engine.on_bar e (bar ~ts:150 ~px:99.0);
  Alcotest.(check int) "no new order from stale bar"
    after_first (Recording_broker.count rec_);
  (* Equal-ts is also idempotent (strictly greater required). *)
  Live_engine.on_bar e (bar ~ts:200 ~px:105.0);
  Alcotest.(check int) "no new order from same-ts bar"
    after_first (Recording_broker.count rec_)

let test_position_tracks_intent () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  (* Three bars with a constant Enter_long signal → two orders
     (first bar queues, next two fire pending and queue fresh).
     Position grows monotonically. *)
  List.iter (fun ts ->
    Live_engine.on_bar e (bar ~ts ~px:100.0)
  ) [100; 200; 300];
  Alcotest.(check int) "two orders over three bars"
    2 (Recording_broker.count rec_);
  Alcotest.(check bool) "position grew"
    true (Decimal.is_positive (Live_engine.position e))

let test_client_order_ids_unique () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  List.iter (fun ts ->
    Live_engine.on_bar e (bar ~ts ~px:100.0)
  ) [100; 200; 300; 400];
  let cids = List.map
    (fun (r : Recording_broker.record) -> r.client_order_id)
    (Recording_broker.records rec_) in
  let unique = List.sort_uniq compare cids in
  Alcotest.(check int) "all cids unique"
    (List.length cids) (List.length unique)

let tests = [
  "enter_long places buy",       `Quick, test_enter_long_places_buy;
  "hold places nothing",         `Quick, test_hold_places_nothing;
  "exit_long when flat no-op",   `Quick, test_exit_long_when_flat_is_noop;
  "out-of-order bar ignored",    `Quick, test_out_of_order_bar_ignored;
  "position tracks intent",      `Quick, test_position_tracks_intent;
  "client_order_ids unique",     `Quick, test_client_order_ids_unique;
  "enter then exit roundtrip",   `Quick, test_enter_then_exit_roundtrip;
]

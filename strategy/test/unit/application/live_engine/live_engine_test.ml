open Core

let d = Decimal.of_float
let d_int = Decimal.of_int

let mk_instrument ticker =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string "MISX") ()

let bar ~ts ~px =
  Candle.make ~ts:(Int64.of_int ts) ~open_:(d px) ~high:(d px) ~low:(d px) ~close:(d px)
    ~volume:(d_int 1)

(** Mock broker that records every place_order call AND
    synchronously confirms it back as a fill. Emulates a zero-latency
    broker so tests can assert on committed portfolio state without
    bringing up Paper + bar feeding. *)
module Recording_broker = struct
  type record = {
    client_order_id : string;
    side : Side.t;
    quantity : Decimal.t;
    kind : Order.kind;
  }

  type t = { mutable placed : record list; mutable on_place : (record -> unit) list }

  let create () = { placed = []; on_place = [] }
  let records t = List.rev t.placed
  let count t = List.length t.placed
  let on_place t cb = t.on_place <- cb :: t.on_place
end

let mk_broker (rec_ : Recording_broker.t) : Broker.client =
  let module M = struct
    type t = Recording_broker.t
    let name = "recording"
    let bars _ ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues _ = []
    let place_order rec_ ~instrument ~side ~quantity ~kind ~tif ~client_order_id =
      let open Recording_broker in
      let r = { client_order_id; side; quantity; kind } in
      rec_.placed <- r :: rec_.placed;
      List.iter (fun cb -> cb r) (List.rev rec_.on_place);
      {
        Order.id = client_order_id;
        exec_id = "";
        instrument;
        side;
        quantity;
        filled = Decimal.zero;
        remaining = quantity;
        kind;
        tif;
        status = Order.New;
        created_ts = 0L;
        client_order_id;
      }
    let get_orders _ = []
    let get_order _ ~client_order_id:_ = failwith "n/a"
    let cancel_order _ ~client_order_id:_ = failwith "n/a"
    let get_executions _ ~client_order_id:_ = []
    let generate_client_order_id =
      let n = ref 0 in
      fun _ ->
        incr n;
        Printf.sprintf "test-cid-%d" !n
  end in
  Broker.make (module M) rec_

(** Queue placed orders as "pending broker confirmations" and return
    a [flush] function that drains them into the engine via
    {!Live_engine.on_fill_event}. Deferred to avoid mutex reentrance
    — [on_place] fires *inside* [Live_engine.submit_order], which is
    itself under the engine's mutex. Real brokers deliver fills on a
    separate WS frame, so this also emulates production timing. *)
let auto_confirm_fills (rec_ : Recording_broker.t) (eng : Live_engine.t) =
  let pending = Queue.create () in
  Recording_broker.on_place rec_ (fun r -> Queue.push r pending);
  fun () ->
    while not (Queue.is_empty pending) do
      let (r : Recording_broker.record) = Queue.pop pending in
      Live_engine.on_fill_event eng
        {
          client_order_id = r.client_order_id;
          actual_quantity = r.quantity;
          actual_price = d 100.0;
          actual_fee = Decimal.zero;
        }
    done

let drive flush e bars =
  List.iter
    (fun c ->
      Live_engine.on_bar e c;
      flush ())
    bars

(** Fixed-signal strategy: always emits the configured action with
    strength 0.5. Lets us drive the engine's translation logic
    directly, without depending on indicator behaviour. *)
module Fixed_signal_strategy = struct
  type params = { action : Signal.action }
  type state = { action : Signal.action }

  let name = "fixed"
  let default_params : params = { action = Signal.Hold }
  let init (p : params) : state = { action = p.action }

  let on_candle (s : state) (instrument : Instrument.t) (c : Candle.t) : state * Signal.t
      =
    ( s,
      {
        ts = c.Candle.ts;
        instrument;
        action = s.action;
        strength = 0.5;
        stop_loss = None;
        take_profit = None;
        reason = "fixed";
      } )
end

let mk_engine ~broker ~action =
  let strat = Strategies.Strategy.make (module Fixed_signal_strategy) { action } in
  let equity = d_int 1_000_000 in
  let cfg : Live_engine.config =
    {
      broker;
      strategy = strat;
      instrument = mk_instrument "SBER";
      initial_cash = equity;
      limits = Engine.Risk.default_limits ~equity;
      tif = Order.DAY;
      fee_rate = 0.0;
      reconcile_every = 0;
      max_drawdown_pct = 0.0;
      rate_limit = None;
    }
  in
  Live_engine.make cfg

(* Pending-signal semantics: a signal on bar T fires an order at bar
   T+1's open. Tests feed two bars — the first produces the signal,
   the second executes it. *)

let test_enter_long_places_buy () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Alcotest.(check int) "no order until next bar" 0 (Recording_broker.count rec_);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  Alcotest.(check int) "one order placed" 1 (Recording_broker.count rec_);
  match Recording_broker.records rec_ with
  | [ r ] ->
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
    ( (),
      {
        ts = c.ts;
        instrument;
        action;
        strength = 0.5;
        stop_loss = None;
        take_profit = None;
        reason = "scripted";
      } )
end

let test_enter_then_exit_roundtrip () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let strat = Strategies.Strategy.make (module Scripted_strategy) () in
  let equity = d_int 1_000_000 in
  let cfg : Live_engine.config =
    {
      broker;
      strategy = strat;
      instrument = mk_instrument "SBER";
      initial_cash = equity;
      limits = Engine.Risk.default_limits ~equity;
      tif = Order.DAY;
      fee_rate = 0.0;
      reconcile_every = 0;
      max_drawdown_pct = 0.0;
      rate_limit = None;
    }
  in
  let e = Live_engine.make cfg in
  let flush = auto_confirm_fills rec_ e in
  (* Bar 100: strategy emits Enter_long → queued; no order yet. *)
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  flush ();
  Alcotest.(check int) "no order on signal bar" 0 (Recording_broker.count rec_);
  (* Bar 200: pending Enter executes at open[200]; new signal Exit
     gets queued for next bar. *)
  Live_engine.on_bar e (bar ~ts:200 ~px:101.0);
  flush ();
  Alcotest.(check int) "one order after enter executes" 1 (Recording_broker.count rec_);
  let qty = Live_engine.position e in
  Alcotest.(check bool) "long after enter" true (Decimal.is_positive qty);
  (* Bar 300: pending Exit executes. Strategy emits Hold, nothing queued. *)
  Live_engine.on_bar e (bar ~ts:300 ~px:102.0);
  flush ();
  Alcotest.(check int) "two orders after exit" 2 (Recording_broker.count rec_);
  Alcotest.(check bool) "flat after exit" true (Decimal.is_zero (Live_engine.position e));
  match Recording_broker.records rec_ with
  | [ enter; exit_ ] ->
      Alcotest.(check string) "enter side" "BUY" (Side.to_string enter.side);
      Alcotest.(check string) "exit side" "SELL" (Side.to_string exit_.side);
      Alcotest.(check bool)
        "exit qty matches entry" true
        (Decimal.equal enter.quantity exit_.quantity)
  | _ -> Alcotest.fail "expected exactly two records"

let test_exit_long_when_flat_is_noop () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Exit_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  Alcotest.(check int) "no order from exit-when-flat" 0 (Recording_broker.count rec_);
  Alcotest.(check bool)
    "position still zero" true
    (Decimal.is_zero (Live_engine.position e))

let test_out_of_order_bar_ignored () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  (* queues Enter *)
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  (* fires at open[200] *)
  let after_first = Recording_broker.count rec_ in
  Alcotest.(check int) "one order after two-bar warmup" 1 after_first;
  (* Feed an older bar — should be dropped, no second order. *)
  Live_engine.on_bar e (bar ~ts:150 ~px:99.0);
  Alcotest.(check int)
    "no new order from stale bar" after_first (Recording_broker.count rec_);
  (* Equal-ts is also idempotent (strictly greater required). *)
  Live_engine.on_bar e (bar ~ts:200 ~px:105.0);
  Alcotest.(check int)
    "no new order from same-ts bar" after_first (Recording_broker.count rec_)

let test_position_tracks_intent () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  let flush = auto_confirm_fills rec_ e in
  (* Three bars with a constant Enter_long signal → two orders
     (first bar queues, next two fire pending and queue fresh).
     Position grows monotonically. *)
  drive flush e (List.map (fun ts -> bar ~ts ~px:100.0) [ 100; 200; 300 ]);
  Alcotest.(check int) "two orders over three bars" 2 (Recording_broker.count rec_);
  Alcotest.(check bool)
    "position grew" true
    (Decimal.is_positive (Live_engine.position e))

let test_client_order_ids_unique () =
  let rec_ = Recording_broker.create () in
  let broker = mk_broker rec_ in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  List.iter (fun ts -> Live_engine.on_bar e (bar ~ts ~px:100.0)) [ 100; 200; 300; 400 ];
  let cids =
    List.map
      (fun (r : Recording_broker.record) -> r.client_order_id)
      (Recording_broker.records rec_)
  in
  let unique = List.sort_uniq compare cids in
  Alcotest.(check int) "all cids unique" (List.length cids) (List.length unique)

(** Broker that reports arbitrary order status on [get_orders] —
    lets us drive [reconcile] through the full status state machine
    without a real WS bridge. *)
module Reporting_broker = struct
  type t = { mutable orders : Order.t list }
  let create () = { orders = [] }
  let set_orders t os = t.orders <- os
end

let mk_reporting_broker (r : Reporting_broker.t) : Broker.client =
  let module M = struct
    type t = Reporting_broker.t
    let name = "reporting"
    let bars _ ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues _ = []
    let place_order
        (r : Reporting_broker.t)
        ~instrument
        ~side
        ~quantity
        ~kind
        ~tif
        ~client_order_id =
      let o =
        {
          Order.id = client_order_id;
          exec_id = "";
          instrument;
          side;
          quantity;
          filled = Decimal.zero;
          remaining = quantity;
          kind;
          tif;
          status = Order.New;
          created_ts = 0L;
          client_order_id;
        }
      in
      r.orders <- o :: r.orders;
      o
    let get_orders (r : Reporting_broker.t) = r.orders
    let get_order _ ~client_order_id:_ = failwith "n/a"
    let cancel_order _ ~client_order_id:_ = failwith "n/a"
    let get_executions _ ~client_order_id:_ = []
    let generate_client_order_id =
      let n = ref 0 in
      fun _ ->
        incr n;
        Printf.sprintf "test-cid-%d" !n
  end in
  Broker.make (module M) r

let set_status (r : Reporting_broker.t) cid status =
  r.orders <-
    List.map
      (fun (o : Order.t) -> if o.client_order_id = cid then { o with status } else o)
      r.orders

let test_reconcile_commits_filled () =
  let r = Reporting_broker.create () in
  let broker = mk_reporting_broker r in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  (* order placed *)
  (* At this point the reservation is open; broker says New. *)
  Alcotest.(check bool) "still not filled" true (Decimal.is_zero (Live_engine.position e));
  (* Broker updates status to Filled. *)
  (match Reporting_broker.(r.orders) with
  | [ o ] -> set_status r o.client_order_id Order.Filled
  | _ -> Alcotest.fail "expected one order");
  Live_engine.reconcile e;
  Alcotest.(check bool)
    "position after reconcile" true
    (Decimal.is_positive (Live_engine.position e))

let test_reconcile_releases_rejected () =
  let r = Reporting_broker.create () in
  let broker = mk_reporting_broker r in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  let before = Account.Portfolio.available_cash (Live_engine.portfolio e) in
  (match Reporting_broker.(r.orders) with
  | [ o ] -> set_status r o.client_order_id Order.Rejected
  | _ -> Alcotest.fail "expected one order");
  Live_engine.reconcile e;
  let after = Account.Portfolio.available_cash (Live_engine.portfolio e) in
  Alcotest.(check bool)
    "reservation released → available_cash grows" true
    (Decimal.compare after before > 0)

let test_reconcile_idempotent () =
  let r = Reporting_broker.create () in
  let broker = mk_reporting_broker r in
  let e = mk_engine ~broker ~action:Signal.Enter_long in
  Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
  Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
  (match Reporting_broker.(r.orders) with
  | [ o ] -> set_status r o.client_order_id Order.Filled
  | _ -> Alcotest.fail "expected one order");
  Live_engine.reconcile e;
  let pos1 = Live_engine.position e in
  (* Second reconcile shouldn't double-commit; pending map is empty. *)
  Live_engine.reconcile e;
  let pos2 = Live_engine.position e in
  Alcotest.(check bool)
    "position unchanged on second reconcile" true (Decimal.equal pos1 pos2)

let tests =
  [
    ("enter_long places buy", `Quick, test_enter_long_places_buy);
    ("hold places nothing", `Quick, test_hold_places_nothing);
    ("exit_long when flat no-op", `Quick, test_exit_long_when_flat_is_noop);
    ("out-of-order bar ignored", `Quick, test_out_of_order_bar_ignored);
    ("position tracks intent", `Quick, test_position_tracks_intent);
    ("client_order_ids unique", `Quick, test_client_order_ids_unique);
    ("enter then exit roundtrip", `Quick, test_enter_then_exit_roundtrip);
    ("reconcile commits filled", `Quick, test_reconcile_commits_filled);
    ("reconcile releases rejected", `Quick, test_reconcile_releases_rejected);
    ("reconcile idempotent", `Quick, test_reconcile_idempotent);
    ( "kill switch halts on drawdown",
      `Quick,
      fun () ->
        (* After a profitable Enter_long, simulate a drawdown via a
       price drop on subsequent bars. With max_drawdown_pct=0.10,
       a 10% drop in equity should trip the switch. Once tripped,
       further signals do NOT produce broker submissions. *)
        let rec_ = Recording_broker.create () in
        let broker = mk_broker rec_ in
        let strat =
          Strategies.Strategy.make
            (module Fixed_signal_strategy)
            { action = Signal.Enter_long }
        in
        let equity = d_int 100_000 in
        let cfg : Live_engine.config =
          {
            broker;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.0;
            reconcile_every = 0;
            max_drawdown_pct = 0.10;
            rate_limit = None;
          }
        in
        let e = Live_engine.make cfg in
        let flush = auto_confirm_fills rec_ e in
        (* Build up a long position at 100. *)
        Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
        flush ();
        Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
        flush ();
        Live_engine.on_bar e (bar ~ts:300 ~px:100.0);
        flush ();
        let orders_at_peak = Recording_broker.count rec_ in
        Alcotest.(check bool) "not halted at peak" false (Live_engine.halted e);
        (* Position after 2 fills ≈ 400 shares @ 100. Price crash to 70
       → equity drops from 100k to 88k, drawdown 12% > 10%. *)
        Live_engine.on_bar e (bar ~ts:400 ~px:70.0);
        Alcotest.(check bool) "halted after drawdown" true (Live_engine.halted e);
        (* Further bars do not produce new orders (gate drops them). *)
        Live_engine.on_bar e (bar ~ts:500 ~px:70.0);
        flush ();
        Live_engine.on_bar e (bar ~ts:600 ~px:70.0);
        flush ();
        Alcotest.(check int)
          "no new orders while halted" orders_at_peak (Recording_broker.count rec_) );
    ( "rate limit drops excess orders",
      `Quick,
      fun () ->
        (* max_orders=2 within 60s. First two enters get through; the
       third is dropped + reservation released. *)
        let rec_ = Recording_broker.create () in
        let broker = mk_broker rec_ in
        let strat =
          Strategies.Strategy.make
            (module Fixed_signal_strategy)
            { action = Signal.Enter_long }
        in
        let equity = d_int 1_000_000 in
        let cfg : Live_engine.config =
          {
            broker;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.0;
            reconcile_every = 0;
            max_drawdown_pct = 0.0;
            rate_limit = Some (2, 60.0);
          }
        in
        let e = Live_engine.make cfg in
        let flush = auto_confirm_fills rec_ e in
        (* 5 bars → 4 potential orders (bar 1 just queues the first
       signal). Rate limit caps at 2. *)
        List.iter
          (fun ts ->
            Live_engine.on_bar e (bar ~ts ~px:100.0);
            flush ())
          [ 100; 200; 300; 400; 500 ];
        Alcotest.(check int) "rate-limited to 2 orders" 2 (Recording_broker.count rec_) );
    ( "kill switch reset clears halted",
      `Quick,
      fun () ->
        let rec_ = Recording_broker.create () in
        let broker = mk_broker rec_ in
        let strat =
          Strategies.Strategy.make
            (module Fixed_signal_strategy)
            { action = Signal.Enter_long }
        in
        let equity = d_int 100_000 in
        let cfg : Live_engine.config =
          {
            broker;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.0;
            reconcile_every = 0;
            max_drawdown_pct = 0.05;
            rate_limit = None;
          }
        in
        let e = Live_engine.make cfg in
        let flush = auto_confirm_fills rec_ e in
        Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
        flush ();
        Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
        flush ();
        Live_engine.on_bar e (bar ~ts:300 ~px:70.0);
        Alcotest.(check bool) "tripped" true (Live_engine.halted e);
        Live_engine.reset e;
        Alcotest.(check bool) "cleared after reset" false (Live_engine.halted e) );
    ( "reconcile uses actual execution prices via Paper",
      `Quick,
      fun () ->
        (* No on_fill subscription — reconcile is the sole commit path.
       Paper fills at actual open[T+1] which differs from Step's
       intended price computed at close[T]. If reconcile used
       intended, Live's cash would diverge from Paper's. *)
        let paper =
          Paper.Paper_broker.make ~initial_cash:(d_int 100_000) ~fee_rate:0.01
            ~source:
              (let module S = struct
                 type t = unit
                 let name = "stub"
                 let bars () ~n:_ ~instrument:_ ~timeframe:_ = []
                 let venues () = []
                 let place_order
                     ()
                     ~instrument:_
                     ~side:_
                     ~quantity:_
                     ~kind:_
                     ~tif:_
                     ~client_order_id:_ =
                   failwith "n/a"
                 let get_orders () = []
                 let get_order () ~client_order_id:_ = failwith "n/a"
                 let cancel_order () ~client_order_id:_ = failwith "n/a"
                 let get_executions () ~client_order_id:_ = []
                 let generate_client_order_id =
                   let n = ref 0 in
                   fun _ ->
                     incr n;
                     Printf.sprintf "test-cid-%d" !n
               end in
               Broker.make (module S) ())
            ()
        in
        let strat =
          Strategies.Strategy.make (module Fixed_signal_strategy) { action = Enter_long }
        in
        let equity = d_int 100_000 in
        let cfg : Live_engine.config =
          {
            broker = Paper.Paper_broker.as_broker paper;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.01;
            reconcile_every = 0;
            max_drawdown_pct = 0.0;
            rate_limit = None;
          }
        in
        let eng = Live_engine.make cfg in
        let inst = mk_instrument "SBER" in
        (* Bar T: signal queued. Fill intended at close[T]=100. *)
        Live_engine.on_bar eng (bar ~ts:100 ~px:100.0);
        Paper.Paper_broker.on_bar paper ~instrument:inst
          (Candle.make ~ts:100L ~open_:(d 100.0) ~high:(d 100.0) ~low:(d 100.0)
             ~close:(d 100.0) ~volume:(d_int 1_000));
        (* Bar T+1: Pipeline reserves. Paper fills at open[T+1]=105
       (gap-up), so actual price = 105, NOT intended 100. *)
        Live_engine.on_bar eng (bar ~ts:200 ~px:105.0);
        Paper.Paper_broker.on_bar paper ~instrument:inst
          (Candle.make ~ts:200L ~open_:(d 105.0) ~high:(d 105.0) ~low:(d 105.0)
             ~close:(d 105.0) ~volume:(d_int 1_000));
        Live_engine.reconcile eng;
        let live_cash = (Live_engine.portfolio eng).cash in
        let paper_cash = (Paper.Paper_broker.portfolio paper).cash in
        Alcotest.(check (float 1e-4))
          "reconcile pulled actual execution numbers" (Decimal.to_float paper_cash)
          (Decimal.to_float live_cash) );
    ( "auto-reconcile after N bars",
      `Quick,
      fun () ->
        let r = Reporting_broker.create () in
        let broker = mk_reporting_broker r in
        let strat =
          Strategies.Strategy.make
            (module Fixed_signal_strategy)
            { action = Signal.Enter_long }
        in
        let equity = d_int 1_000_000 in
        let cfg : Live_engine.config =
          {
            broker;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.0;
            reconcile_every = 3;
            max_drawdown_pct = 0.0;
            rate_limit = None;
            (* every 3 bars *)
          }
        in
        let e = Live_engine.make cfg in
        (* Bar 1: signal queued. Bar 2: signal fires → order placed,
       reservation created. Broker reports New. Bars 3-4: further
       signals / orders. After bar 3 (3 bars total), auto-reconcile
       should trigger — broker still has New, so nothing committed.
       Mark the order as Filled, then feed one more bar (bar 4) —
       count was reset at bar 3, so bar 4 is counter 1. No trigger
       yet. Feed bars 5, 6 → counter reaches 3 again → reconcile
       runs, commits the Filled order. *)
        Live_engine.on_bar e (bar ~ts:100 ~px:100.0);
        Live_engine.on_bar e (bar ~ts:200 ~px:100.0);
        Live_engine.on_bar e (bar ~ts:300 ~px:100.0);
        (* Mark the first order as Filled *)
        (match Reporting_broker.(r.orders) with
        | o :: _ -> set_status r o.client_order_id Order.Filled
        | [] -> Alcotest.fail "no orders placed yet");
        (* Position not committed yet — reconcile hasn't seen Filled. *)
        let pos_before = Live_engine.position e in
        Alcotest.(check bool)
          "no commit before next trigger" true (Decimal.is_zero pos_before);
        (* Three more bars → counter reaches 3 → auto-reconcile fires. *)
        Live_engine.on_bar e (bar ~ts:400 ~px:100.0);
        Live_engine.on_bar e (bar ~ts:500 ~px:100.0);
        Live_engine.on_bar e (bar ~ts:600 ~px:100.0);
        Alcotest.(check bool)
          "auto-reconcile committed Filled order" true
          (Decimal.is_positive (Live_engine.position e)) );
    ( "partial fills via paper",
      `Quick,
      fun () ->
        (* Paper with participation_rate=0.25 splits a 10-qty order
       over multiple bars; Live_engine should commit each slice via
       commit_partial_fill and finish with the full qty committed. *)
        let source =
          Paper.Paper_broker.make ~initial_cash:(d_int 100_000) ~participation_rate:0.25
            ~source:
              (let module S = struct
                 type t = unit
                 let name = "stub"
                 let bars () ~n:_ ~instrument:_ ~timeframe:_ = []
                 let venues () = []
                 let place_order
                     ()
                     ~instrument:_
                     ~side:_
                     ~quantity:_
                     ~kind:_
                     ~tif:_
                     ~client_order_id:_ =
                   failwith "n/a"
                 let get_orders () = []
                 let get_order () ~client_order_id:_ = failwith "n/a"
                 let cancel_order () ~client_order_id:_ = failwith "n/a"
                 let get_executions () ~client_order_id:_ = []
                 let generate_client_order_id =
                   let n = ref 0 in
                   fun _ ->
                     incr n;
                     Printf.sprintf "test-cid-%d" !n
               end in
               Broker.make (module S) ())
            ()
        in
        let strat =
          Strategies.Strategy.make (module Fixed_signal_strategy) { action = Enter_long }
        in
        let equity = d_int 100_000 in
        let cfg : Live_engine.config =
          {
            broker = Paper.Paper_broker.as_broker source;
            strategy = strat;
            instrument = mk_instrument "SBER";
            initial_cash = equity;
            limits = Engine.Risk.default_limits ~equity;
            tif = Order.DAY;
            fee_rate = 0.0;
            reconcile_every = 0;
            max_drawdown_pct = 0.0;
            rate_limit = None;
          }
        in
        let eng = Live_engine.make cfg in
        Paper.Paper_broker.on_fill source (fun (f : Paper.Paper_broker.fill) ->
            Live_engine.on_fill_event eng
              {
                client_order_id = f.client_order_id;
                actual_quantity = f.quantity;
                actual_price = f.price;
                actual_fee = f.fee;
              });
        (* Feed bars with volume=20 → participation cap = 5/bar.
       Fixed_signal emits Enter_long every bar → sizing will pick
       some qty. We drive 5 bars to let fills accumulate. *)
        let inst = mk_instrument "SBER" in
        let mk_bar ts px =
          Candle.make ~ts:(Int64.of_int ts) ~open_:(d px) ~high:(d px) ~low:(d px)
            ~close:(d px) ~volume:(d_int 20)
        in
        let candles =
          List.map (fun ts -> mk_bar ts 100.0) [ 100; 200; 300; 400; 500; 600; 700; 800 ]
        in
        List.iter
          (fun c ->
            Live_engine.on_bar eng c;
            Paper.Paper_broker.on_bar source ~instrument:inst c)
          candles;
        (* After several bars, Live should have committed position > 0
       and paper's fills count > orders submitted (partials). *)
        let live_pos = Live_engine.position eng in
        let paper_fills = Paper.Paper_broker.fills source in
        Alcotest.(check bool)
          "Live position grew via partials" true
          (Decimal.is_positive live_pos);
        Alcotest.(check bool)
          "Paper emitted multiple fill events" true
          (List.length paper_fills >= 2);
        (* Live's portfolio should match Paper's (both produced from
       the same sequence of actual fill events). *)
        let live_cash = (Live_engine.portfolio eng).cash in
        let paper_cash = (Paper.Paper_broker.portfolio source).cash in
        Alcotest.(check (float 1e-6))
          "Live cash == Paper cash after partial fills" (Decimal.to_float paper_cash)
          (Decimal.to_float live_cash) );
  ]

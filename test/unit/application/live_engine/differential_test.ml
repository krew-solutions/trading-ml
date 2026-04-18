(** Differential test: same strategy + same candles must produce
    identical fills whether run through {!Engine.Backtest.run} or
    through {!Live_engine} + {!Paper.Paper_broker}.

    The two paths share [Risk.size_from_strength], [Risk.check] and
    [Portfolio.fill] — only the plumbing differs. Any divergence is a
    regression that would otherwise surface as "paper P&L disagrees
    with backtest P&L for the same signal stream". *)

open Core

let d = Decimal.of_float
let d_int = Decimal.of_int

let mk_instrument ticker = Instrument.make
  ~ticker:(Ticker.of_string ticker)
  ~venue:(Mic.of_string "MISX") ()

(** Stub market-data source — Paper's [bars] and [venues] are
    irrelevant for this test; we feed bars to Paper via [on_bar]. *)
let mk_stub_source () : Broker.client =
  let module M = struct
    type t = unit
    let name = "stub"
    let bars () ~n:_ ~instrument:_ ~timeframe:_ = []
    let venues () = []
    let place_order () ~instrument:_ ~side:_ ~quantity:_
        ~kind:_ ~tif:_ ~client_order_id:_ = failwith "n/a"
    let get_orders () = []
    let get_order () ~client_order_id:_ = failwith "n/a"
    let cancel_order () ~client_order_id:_ = failwith "n/a"
    let get_executions () ~client_order_id:_ = []
  end in
  Broker.make (module M) ()

(** Deterministic sine-wave price series — enough oscillation to
    provoke crossovers under standard SMA defaults. *)
let sine_candles n =
  List.init n (fun i ->
    let t = float_of_int i in
    let px = 100.0 +. 10.0 *. sin (t /. 10.0) in
    Candle.make
      ~ts:(Int64.of_int (i * 60))
      ~open_:(d px) ~high:(d (px +. 0.1))
      ~low:(d (px -. 0.1)) ~close:(d px)
      ~volume:(d_int 1000))

let equity_init = d_int 1_000_000
let fee_rate = 0.0005

let run_backtest instrument candles =
  let cfg : Engine.Backtest.config = {
    initial_cash = equity_init;
    fee_rate;
    limits = Engine.Risk.default_limits ~equity:equity_init;
  } in
  let strat = Strategies.Strategy.default (module Strategies.Sma_crossover) in
  Engine.Backtest.run ~config:cfg ~strategy:strat ~instrument ~candles

let run_live instrument candles =
  let paper = Paper.Paper_broker.make
    ~initial_cash:equity_init
    ~fee_rate
    ~source:(mk_stub_source ()) () in
  let strat = Strategies.Strategy.default (module Strategies.Sma_crossover) in
  let cfg : Live_engine.config = {
    broker = Paper.Paper_broker.as_broker paper;
    strategy = strat;
    instrument;
    initial_cash = equity_init;
    limits = Engine.Risk.default_limits ~equity:equity_init;
    tif = Order.DAY;
    fee_rate; reconcile_every = 0;
  } in
  let eng = Live_engine.make cfg in
  (* Wire Paper's fill events to Live_engine's reservation commit.
     This is the production wiring too — main.ml does the same. *)
  Paper.Paper_broker.on_fill paper (fun (f : Paper.Paper_broker.fill) ->
    Live_engine.on_fill_event eng {
      client_order_id = f.client_order_id;
      actual_quantity = f.quantity;
      actual_price = f.price;
      actual_fee = f.fee;
    });
  List.iter (fun c ->
    (* Order matters: Live_engine.on_bar must run *before* Paper's
       last_ts advances, so the order Paper records [placed_after_ts]
       at the previous bar's ts. Then Paper.on_bar fills the pending
       order at [c.open_] and synchronously fires the on_fill
       callback, which triggers Live_engine.on_fill_event to
       commit the reservation. *)
    Live_engine.on_bar eng c;
    Paper.Paper_broker.on_bar paper ~instrument c
  ) candles;
  eng, paper

let test_fills_match () =
  let instrument = mk_instrument "SBER" in
  let candles = sine_candles 200 in
  let r = run_backtest instrument candles in
  let _eng, paper = run_live instrument candles in
  let paper_fills = Paper.Paper_broker.fills paper in
  Alcotest.(check int) "same number of fills"
    (List.length r.fills) (List.length paper_fills);
  List.iter2
    (fun (bt : Engine.Backtest.fill) (p : Paper.Paper_broker.fill) ->
      Alcotest.(check string) "side"
        (Side.to_string bt.side) (Side.to_string p.side);
      Alcotest.(check (float 1e-6)) "qty"
        (Decimal.to_float bt.quantity) (Decimal.to_float p.quantity);
      Alcotest.(check (float 1e-6)) "price"
        (Decimal.to_float bt.price) (Decimal.to_float p.price);
      Alcotest.(check (float 1e-6)) "fee"
        (Decimal.to_float bt.fee) (Decimal.to_float p.fee))
    r.fills paper_fills

let test_portfolios_match () =
  let instrument = mk_instrument "SBER" in
  let candles = sine_candles 200 in
  let r = run_backtest instrument candles in
  let eng, paper = run_live instrument candles in
  let eng_p = Live_engine.portfolio eng in
  let paper_p = Paper.Paper_broker.portfolio paper in
  Alcotest.(check (float 1e-6)) "engine cash == backtest cash"
    (Decimal.to_float r.final.cash)
    (Decimal.to_float eng_p.cash);
  Alcotest.(check (float 1e-6)) "paper cash == backtest cash"
    (Decimal.to_float r.final.cash)
    (Decimal.to_float paper_p.cash);
  Alcotest.(check (float 1e-6)) "engine realized_pnl == backtest"
    (Decimal.to_float r.final.realized_pnl)
    (Decimal.to_float eng_p.realized_pnl);
  Alcotest.(check (float 1e-6)) "paper realized_pnl == backtest"
    (Decimal.to_float r.final.realized_pnl)
    (Decimal.to_float paper_p.realized_pnl)

let test_non_trivial_activity () =
  (* Sanity: the chosen candle series actually produces trades. A
     passing "same fills" check is worthless if both sides produce
     zero fills. *)
  let instrument = mk_instrument "SBER" in
  let candles = sine_candles 200 in
  let r = run_backtest instrument candles in
  Alcotest.(check bool) "backtest produced at least one fill"
    true (List.length r.fills > 0)

let tests = [
  "fills match bar-by-bar",      `Quick, test_fills_match;
  "final portfolios match",      `Quick, test_portfolios_match;
  "differential uses real data", `Quick, test_non_trivial_activity;
]

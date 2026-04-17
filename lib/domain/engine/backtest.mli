(** Event-driven backtester. Runs a strategy over a historical candle
    stream, routes signals through the risk gate, executes fills at the
    next bar's open ("next-bar execution" avoids look-ahead bias), and
    records an equity curve.

    All state is explicit and the function is referentially transparent:
    given the same inputs, the same trade log comes out. This is the
    property backtest correctness tests rely on. *)

open Core

(** A single executed fill. *)
type fill = {
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reason : string;
}

(** One step of the equity curve (used internally and in tests). *)
type step = {
  ts : int64;
  equity : Decimal.t;
  cash : Decimal.t;
  signal : Signal.t option;
  fill : fill option;
}

(** Summary of a completed backtest run. *)
type result = {
  final : Portfolio.t;
  fills : fill list;
  equity_curve : (int64 * Decimal.t) list;
  max_drawdown : float;
  total_return : float;
  num_trades : int;
}

(** Backtest configuration. *)
type config = {
  initial_cash : Decimal.t;
  fee_rate : float;
  limits : Risk.limits;
}

(** Sensible defaults: 1M cash, 5 bps fees, standard risk limits. *)
val default_config : ?initial_cash:Decimal.t -> unit -> config

(** [run ~config ~strategy ~instrument ~candles] executes the backtest.
    Candles must be in chronological order. *)
val run :
  config:config ->
  strategy:Strategies.Strategy.t ->
  instrument:Instrument.t ->
  candles:Candle.t list ->
  result

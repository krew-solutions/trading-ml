(** Historical replay driver over {!Step}: folds the shared
    trading state machine across a candle list and aggregates the
    mark-to-market equity curve into summary statistics
    (total_return, max_drawdown).

    Referentially transparent: given the same strategy, config and
    candle series, the same [result] comes out. {!Live_engine}
    drives the same {!Step} primitives on streaming bars, so paper
    P&L matches a backtest on identical data. *)

open Core

type fill = {
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reason : string;
}
(** A single executed fill. *)

type result = {
  final : Account.Portfolio.t;
  fills : fill list;
  equity_curve : (int64 * Decimal.t) list;
  max_drawdown : float;
  total_return : float;
  num_trades : int;
}
(** Summary of a completed backtest run. *)

type config = { initial_cash : Decimal.t; fee_rate : float; limits : Risk.limits }
(** Backtest configuration. *)

val default_config : ?initial_cash:Decimal.t -> unit -> config
(** Sensible defaults: 1M cash, 5 bps fees, standard risk limits. *)

val run :
  config:config ->
  strategy:Strategies.Strategy.t ->
  instrument:Instrument.t ->
  candles:Candle.t list ->
  result
(** [run ~config ~strategy ~instrument ~candles] executes the backtest.
    Candles must be in chronological order. *)

(** The shared transducer: candle stream in, {!event} stream out.
    Both {!Backtest.run} (materialise + aggregate) and
    {!Live_engine.run} (iter + submit) drive this same function —
    they differ only in how the event stream is consumed, not in
    how state evolves.

    Out-of-order bars are skipped at the pipeline level — the state
    machine never sees a bar with [ts <= last_bar_ts]. Same
    semantics regardless of driver. *)

open Core

(** One bar processed through the trading state machine. *)
type event = {
  bar : Candle.t;
  state : Step.state;
  (** Full state snapshot after this tick. Callers that want the
      portfolio, strategy instance or [last_bar_ts] read them off
      this snapshot. *)
  settled : (Signal.t * Step.settled) option;
  (** Populated iff a pending signal executed at [bar.open_]. The
      carried {!Signal.t} is the one that fired (useful for
      logging / reason tracking); {!Step.settled} has the fill
      side/qty/price/fee. *)
}

val run : Step.config -> Step.state -> Candle.t Stream.t -> event Stream.t
(** [run cfg state0 bars] threads [state0] through [bars] via
    {!Step.execute_pending} + {!Step.advance_strategy}, emitting an
    {!event} per accepted bar.

    Lazy: consumers that [Stream.take] only a prefix won't force the
    tail. Drives a finite stream to exhaustion when consumed fully;
    drives infinite streams forever (e.g. the Eio-backed live
    source). *)

val equity_at_close : event -> Decimal.t
(** Mark-to-market equity using [event.bar.close] as the mark for
    [event.state.portfolio]. Convenience — equivalent to
    [Portfolio.equity event.state.portfolio (fun _ -> Some bar.close)]. *)

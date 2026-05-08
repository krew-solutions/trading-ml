(** Aggregate root: drawdown-based kill switch.

    Tracks peak-since-reset equity and halts submissions when current
    equity falls below [peak × (1 − max_drawdown_pct)]. Once tripped,
    {!is_halted} stays [true] until {!reset} is invoked deliberately;
    {!update_equity} continues to accumulate the peak but does not
    un-halt by itself. Mirrors the original
    [Live_engine.update_drawdown] behaviour, lifted out of strategy
    into its own BC.

    Invariants:
    - [peak_equity ≥ 0];
    - tripped state monotonically requires explicit {!reset} to clear;
    - the threshold is fixed at construction. *)

module Values : module type of Values
module Events : module type of Events

type t

val make : initial_equity:Decimal.t -> max_drawdown_pct:Values.Max_drawdown_pct.t -> t

val peak_equity : t -> Decimal.t
val is_halted : t -> bool
val max_drawdown_pct : t -> Values.Max_drawdown_pct.t

val update_equity :
  t -> equity:Decimal.t -> occurred_at:int64 -> t * Events.Tripped.t option
(** [update_equity ~equity ~occurred_at] grows the peak when [equity]
    exceeds it, and emits [Some Tripped.t] the first time the
    drawdown crosses [max_drawdown_pct] (subsequent calls while
    already halted return [None]). [max_drawdown_pct = 0] disables
    the gate and never trips. *)

val reset : t -> new_peak_equity:Decimal.t -> occurred_at:int64 -> t * Events.Reset.t

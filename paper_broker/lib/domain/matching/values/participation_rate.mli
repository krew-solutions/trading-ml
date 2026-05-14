(** Liquidity cap expressed as a fraction of bar volume: the maximum
    share of a single bar's traded volume that the simulator allows a
    single matched order to consume.

    Applied by {!Matching.fillable_qty}: a working order with
    [remaining] quantity fills at most [bar.volume * rate] units on
    any given bar; the residual stays working for subsequent bars.
    Without a participation cap, a backtest on low-volume bars can
    silently produce unrealistic fills (e.g. lifting 1M shares on a
    bar that printed only 1k), so the cap exists to keep
    paper-trading results faithful to what a real venue would
    actually absorb.

    Invariants:
    - [rate > 0] — a cap of zero is degenerate (no order would
      ever fill);
    - [rate <= 1] — claiming more than a bar's printed volume is
      meaningless: the bar is the upper bound of available
      liquidity at that price tick. *)

type t = private Decimal.t

val of_decimal : Decimal.t -> t
(** Raises [Invalid_argument] when [d <= 0] or [d > 1]. *)

val to_decimal : t -> Decimal.t

val one : t
(** [1] — "take the entire bar's volume" cap. The canonical setting
    when the deployment wants to enforce the upper bound only
    (rather than truly limiting share). *)

val equal : t -> t -> bool
val compare : t -> t -> int

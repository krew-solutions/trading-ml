(** Internal state of {!Pair_mean_reversion}.

    Holds:
    - the policy [config];
    - per-leg latest log-close cache (so spread samples can be paired
      asynchronously across legs);
    - rolling ring of the last [config.window] spread observations;
    - current spread [direction] (Flat / Long_spread / Short_spread)
      used to enforce hysteresis at the edges.

    Pure value type — every transition returns a fresh [t]. *)

(** Direction of the open position, in spread terms. *)
module Direction : sig
  type t = Flat | Long_spread | Short_spread

  val equal : t -> t -> bool
end

type t

val init : Pair_mr_config.t -> t

val config : t -> Pair_mr_config.t
val direction : t -> Direction.t

val sample_count : t -> int
(** Number of spread observations in the rolling ring. *)

val record_log_close : t -> leg:[ `A | `B ] -> log_close:float -> t
(** Update the per-leg log-close cache. If both legs now have a
    cached close, append a fresh spread observation
    ([log_a − β · log_b]) to the ring. *)

val current_z : t -> float option
(** Standardised residual of the most recent spread w.r.t. the
    rolling mean and population stdev. [None] until the ring is full
    AND stdev is non-zero. *)

val with_direction : t -> Direction.t -> t

val last_log_close : t -> leg:[ `A | `B ] -> float option

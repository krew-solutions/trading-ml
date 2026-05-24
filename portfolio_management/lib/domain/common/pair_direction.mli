(** Directional state of a pair-trading construction policy, in
    spread terms. Shared between {!Pair_mean_reversion} (static β)
    and {!Pair_kalman_mean_reversion} (adaptive β); both run the
    same Flat → Long_spread / Short_spread hysteresis state machine
    over their respective z-score computations.

    Distinct from {!Direction} (which models the bias of a
    single-asset alpha source) — a pair direction names which way
    the {b spread} is leaning, not which way an individual leg is. *)

type t = Flat | Long_spread | Short_spread

val equal : t -> t -> bool

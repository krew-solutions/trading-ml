(** POV — Percent Of Volume — parameters.

    Targets [participation_rate × cumulative_observed_volume] as
    the cumulative emitted quantity. Each incoming [Volume_bar]
    grows the observed volume and unlocks a (potentially zero)
    further emission to maintain the rate.

    The [timeframe] identifies which bar cadence on the volume
    feed the strategy participates against (e.g. ["1m"]). The
    volume-feed adapter filters bars at the boundary so the
    strategy receives only its chosen cadence.

    Invariants:
    - [0 < participation_rate ≤ 1];
    - [timeframe] is non-empty. *)

type t = private { participation_rate : float; timeframe : string }

val make : participation_rate:float -> timeframe:string -> t
(*@ r = make ~participation_rate ~timeframe
    requires participation_rate > 0.0 /\ participation_rate <= 1.0
    requires timeframe <> ""
    ensures r.participation_rate = participation_rate
    ensures r.timeframe = timeframe *)

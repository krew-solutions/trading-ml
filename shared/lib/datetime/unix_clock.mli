(** Wall-clock {!Clock.t}: every read returns the host's current
    Unix epoch seconds via {!Unix.gettimeofday}.

    Used in live deployments. Backtests substitute
    {!Virtual_clock} instead. *)

val make : unit -> Clock.t

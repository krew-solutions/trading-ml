(** Ambient-time port.

    Abstracts the source of "what time is it now" so live and
    backtest deployments can substitute different implementations.
    A [Clock.t] reads epoch seconds (UTC, [int64]) — the same unit
    used across commands, integration events, and {!Iso8601}.

    {b Where this fits.} The Domain Layer never reads ambient time:
    timestamps come in as explicit arguments to its methods. The
    Application Layer is the boundary where ambient time enters,
    and it obtains time from a {!Clock.t} supplied by the
    composition root.

    BC factories typically accept a [~now : unit -> int64] closure
    rather than the full [Clock.t]. Keeping the [Clock] interface
    confined to the composition root prevents the abstraction from
    bleeding into application code that has no business knowing
    "live or backtest".

    Implementations:

    - {!Unix_clock} — wall-clock for live deployments.
    - {!Virtual_clock} — externally-driven for backtest, advanced
      from the simulated bar stream. *)

type t

val of_fn : (unit -> int64) -> t
(** Build a clock from a "read current time" thunk. The thunk is
    expected to return epoch seconds. *)

val now : t -> int64
(** Read the current epoch-seconds time from the clock. *)

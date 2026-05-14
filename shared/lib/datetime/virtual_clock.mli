(** Externally-driven {!Clock.t}: holds a mutable [int64] that
    callers advance from outside the application layer.

    Intended for backtest deployments. The composition root
    typically subscribes a [Virtual_clock.t] to the bar stream so
    every observed bar tick advances ambient time, then exposes it
    to BC factories through a [~now] closure obtained from
    {!as_clock} + {!Clock.now}.

    Initial value defaults to [0L]; reads before the first
    {!set} return [0L]. *)

type t

val make : ?initial:int64 -> unit -> t

val as_clock : t -> Clock.t
(** Expose the virtual clock through the generic {!Clock.t}
    interface so callers don't depend on the concrete
    implementation. *)

val set : t -> int64 -> unit
(** Replace the current reading. Not enforced monotonic — callers
    are responsible for advancing in the order their semantics
    expect (typically the bar stream's [candle.ts]). *)

val read : t -> int64
(** Read the current reading directly, bypassing {!as_clock}. *)

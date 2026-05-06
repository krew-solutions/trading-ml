(** Stateful inbound handler for {!Bar_updated_integration_event.t}.

    The handler buffers decoded bars in an internal {!Eio.Stream.t}
    and exposes them as a pull-driven {!Stream.t} via {!source}.
    {!handle} is the bus callback — composition root subscribes it
    to whichever consumer is appropriate. The internal Eio.Stream is
    the single push→pull boundary on the path from bus to
    {!Live_engine}. *)

module Bar_updated = Bar_updated_integration_event

type t

val make : capacity:int -> t
(** [capacity] sizes the internal Eio.Stream buffer. *)

val source : t -> Core.Candle.t Stream.t
(** Pull-driven candle stream backed by the internal Eio.Stream.
    Single-consumer semantics — pull from one fiber. *)

val handle : t -> instrument:Core.Instrument.t -> Bar_updated.t -> unit
(** Bus callback. Drops events whose instrument does not match
    [instrument]; otherwise decodes the bar and pushes it onto the
    internal stream. *)

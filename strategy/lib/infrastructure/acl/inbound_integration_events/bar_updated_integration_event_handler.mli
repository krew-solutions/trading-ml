(** Handler for the inbound {!Bar_updated_integration_event.t}.

    Sits at the Strategy ACL boundary: subscribes to a bus carrying
    the strategy-side mirror DTO, decodes each event matching the
    configured instrument into a {!Core.Candle.t}, and pushes it into
    an internal {!Eio.Stream.t}. The pull-driven {!source} accessor
    exposes the same stream as a {!Stream.t} via
    {!Eio_stream.of_eio_stream} — that is the single boundary at
    which Eio's push model meets the pure Stream pull model that
    {!Live_engine.run} consumes.

    Functor over {!Bus.Event_bus.S} — composition root applies it
    with whichever concrete bus implementation is in use (in-memory
    today, Kafka tomorrow). *)

module Bar_updated = Bar_updated_integration_event

module Make (Bus : Bus.Event_bus.S) : sig
  type t

  val make : capacity:int -> t
  (** Create a buffered handler. [capacity] sizes the internal
      {!Eio.Stream.t} between the bus subscriber callback (push side)
      and the consumer fiber (pull side via {!source}). Drops are
      not silent: when the buffer fills, {!Eio.Stream.add} blocks
      the bus dispatch fiber until the consumer drains. *)

  val source : t -> Core.Candle.t Stream.t
  (** Pull-driven candle stream backed by the internal {!Eio.Stream.t}.
      Each forced [Cons] blocks the consumer fiber on
      {!Eio.Stream.take} until a matching bar lands on the bus.
      Single-consumer semantics — pull from one fiber. *)

  val attach :
    t -> events:Bar_updated.t Bus.t -> instrument:Core.Instrument.t -> Bus.subscription
  (** Subscribe to [events]. Each inbound DTO whose [instrument]
      decodes to a value equal to the [instrument] argument is
      converted to {!Core.Candle.t} via {!Decimal.of_string} and
      pushed into the internal stream; non-matching events are
      dropped silently. No timeframe filter — {!Live_engine}
      currently has no per-engine timeframe in its config; if mixed
      timeframes leak through, the engine's own [last_bar_ts] guard
      in {!Engine.Pipeline.run} will reject out-of-order bars. *)
end

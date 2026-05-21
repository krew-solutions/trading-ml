(** Handler for inbound BARS events: pushes every candle to the
    in-process Stream registry (so SSE subscribers see it) and
    invokes [publish_bar_updated] for each (so the bus carries it
    cross-BC).

    The handler is intentionally signature-agnostic about how
    publish_bar_updated decides whether to actually emit on the
    bus — monotonicity and intra-bar-dedup live in the caller-
    supplied closure (see [Broker_factory.Factory.build] for the
    canonical implementation).

    When the event arrives without a timeframe (subscription_key
    missing on the wire), [timeframes_fallback] is consulted —
    typically backed by the bridge's "what am I subscribed to
    for this instrument" registry — to fan the bar out to all
    active timeframes for that instrument. *)

open Core

val handle :
  push_to_stream:(instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t -> unit) ->
  publish_bar_updated:
    (instrument:Instrument.t -> timeframe:Timeframe.t -> candle:Candle.t -> unit) ->
  timeframes_fallback:(Instrument.t -> Timeframe.t list) ->
  Bars.t ->
  unit

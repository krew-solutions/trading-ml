(** Handler for inbound BARS events: pushes every candle to the
    in-process Stream registry (so SSE subscribers see it) and
    publishes a [Bar_updated_integration_event] for each (so
    the bus carries it cross-BC).

    When the event arrives without a timeframe (subscription_key
    missing on the wire), [timeframes_fallback] is consulted —
    typically backed by the bridge's "what am I subscribed to
    for this instrument" registry — to fan the bar out to all
    active timeframes for that instrument. *)

open Core

val handle :
  push_to_stream:(instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t -> unit) ->
  publish_bar_updated:(Broker_integration_events.Bar_updated_integration_event.t -> unit) ->
  timeframes_fallback:(Instrument.t -> Timeframe.t list) ->
  Bars.t ->
  unit

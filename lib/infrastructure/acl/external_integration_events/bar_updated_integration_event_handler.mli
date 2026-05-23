(** Inbound translation handler for {!Bar_updated_integration_event.t}.

    Pure ACL: rebuilds [Core.Instrument.t] from the four wire
    identity fields, parses the timeframe string, and rebuilds
    [Core.Candle.t] from the OHLCV strings. The decoded triple is
    forwarded to [push] for the SSE registry to demultiplex by
    [(instrument, timeframe)].

    Malformed payloads (unparseable decimal, unknown timeframe,
    invalid ticker / MIC) are logged and dropped. A single bad
    event must not take down the registry or stall the bus
    dispatcher — every consumer is best-effort. *)

open Core

val handle :
  push:(instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t -> unit) ->
  Bar_updated_integration_event.t ->
  unit

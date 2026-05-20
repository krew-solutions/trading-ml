(** WS request encoders for the BARS channel.

    Builds the SUBSCRIBE / UNSUBSCRIBE envelopes Finam expects
    over its async-api WebSocket. Pure functions: same input →
    same JSON; no I/O. *)

open Core

val subscribe :
  token:string -> instrument:Instrument.t -> timeframe:Timeframe.t -> Yojson.Safe.t

val unsubscribe :
  token:string -> instrument:Instrument.t -> timeframe:Timeframe.t -> Yojson.Safe.t

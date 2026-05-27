(** WS request encoders for the INSTRUMENT_TRADES channel — the public
    tape (all market participants) for a single instrument.

    Envelope: [{ action; type = "INSTRUMENT_TRADES"; data = { symbol };
    token }] (single symbol, unlike QUOTES which takes a list). *)

open Core

val subscribe : token:string -> Instrument.t -> Yojson.Safe.t
val unsubscribe : token:string -> Instrument.t -> Yojson.Safe.t

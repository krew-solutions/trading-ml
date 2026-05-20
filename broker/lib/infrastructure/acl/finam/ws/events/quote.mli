(** Inbound QUOTES event: best bid + best ask for one instrument
    at one moment. Finam ships an array under [payload.quote];
    we surface the first element (most-recent observation). *)

open Core

type t = { instrument : Instrument.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }

val parse : Yojson.Safe.t -> t option
(** Returns [None] when the envelope's [payload.quote] array is
    empty or malformed. *)

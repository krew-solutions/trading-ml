(** Inbound QUOTES event: best bid + best ask for one instrument
    at one moment. Finam ships an array under [payload.quote];
    we surface the first element (most-recent observation). *)

open Core

type t = { instrument : Instrument.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }

val parse : Yojson.Safe.t -> t option
(** Returns [None] when the [payload.quote] array is empty/malformed,
    or when the quote object is a partial (delta) frame that omits
    [bid] / [ask] — Finam emits those when only size / last / volume
    changed, and they carry no usable top-of-book snapshot. *)

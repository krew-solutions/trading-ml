(** Finam instrument routing helpers.
    Extracted from [Rest] to break the Dto↔Rest dependency cycle
    (Dto needs to qualify instruments for PlaceOrder encoding; Rest
    needs Dto for decoding). *)

open Core

let qualify_instrument (i : Instrument.t) : string =
  Ticker.to_string (Instrument.ticker i) ^ "@" ^ Mic.to_string (Instrument.venue i)

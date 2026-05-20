(** Inbound BARS event: a batch of candles for one instrument,
    on one timeframe.

    Timeframe is recovered from the envelope's
    [subscription_key] (formatted as
    ["<TICKER>@<MIC>:<TIMEFRAME>"]) when present; if absent, the
    parser falls back to the symbol from the payload and leaves
    timeframe as [None] for the caller to fill in from the
    bridge's subscription registry. *)

open Core

type t = {
  instrument : Instrument.t;
  timeframe : Timeframe.t option;
  bars : Candle.t list;
}

val parse : Yojson.Safe.t -> t
(** Parses the BARS payload from a full DATA envelope. *)

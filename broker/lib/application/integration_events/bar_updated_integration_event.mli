(** Integration event: an OHLCV bar has been observed for an instrument
    on a given timeframe.

    Published by the broker BC when its upstream venue stream
    delivers a bar (Finam WS / BCS WS).

    Idempotency: subscribers MUST upsert by
    [(instrument, timeframe, bar.ts)]. Repeat publications of the same
    key (intra-bar updates from the venue, late-subscribe, replay,
    reconnect) are part of the contract — the event carries no
    "is this a revision?" flag because such producer-side memory is
    not equivalent to consumer-side delivery state on any non-trivial
    transport. Ordering / deduplication concerns belong to the
    transport layer (e.g. per-key sequence numbers), not the payload.

    DTO-shaped: primitives + nested view models, no domain values. *)

open Core

type t = {
  instrument : Queries.Instrument_view_model.t;
  timeframe : string;  (** [Timeframe.to_string] form. *)
  bar : Queries.Candle_view_model.t;
}
[@@deriving yojson]

val of_domain : instrument:Instrument.t -> timeframe:Timeframe.t -> bar:Candle.t -> t

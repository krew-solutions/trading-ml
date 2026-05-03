(** Integration event: a finalised OHLCV bar has been observed for an
    instrument on a given timeframe.

    Published by the broker BC when its upstream venue stream
    delivers a closed bar (Finam WS / BCS WS / synthetic feed).
    Carries [is_revision] for upstream sources that re-publish
    historical bars with corrections — Nautilus follows the same
    convention. Consumers may filter on it.

    DTO-shaped: primitives + nested view model, no domain values. *)

type t = {
  instrument : Queries.Instrument_view_model.t;
  timeframe : string;  (** ISO-8601 duration / project Timeframe.to_string *)
  bar : Queries.Candle_view_model.t;
  is_revision : bool;
}
[@@deriving yojson]

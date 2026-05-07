(** PM-side inbound DTO mirror of an OHLCV candle view model.

    Structural-only: [ts] is an ISO-8601 datetime string
    ([YYYY-MM-DDTHH:MM:SSZ]); OHLCV are decimal strings (bit-exact
    roundtrip with the upstream [Decimal.to_string] form). No
    [of_domain] / [type domain]. *)

type t = {
  ts : string;  (** ISO-8601 *)
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

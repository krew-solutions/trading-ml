(** Strategy-side inbound DTO mirror of an OHLCV candle view model.

    Structural-only: [ts] is unix epoch seconds int64; OHLCV are
    decimal strings (bit-exact roundtrip with the upstream
    [Decimal.to_string] form). No [of_domain] / [type domain]. *)

type t = {
  ts : int64;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

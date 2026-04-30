(** Read-model DTO for {!Core.Candle.t}.

    OHLCV as primitives: [ts] is a unix epoch-seconds int64,
    prices/volume are decimal strings accepted by
    {!Core.Decimal.of_string} — bit-exact round-trip with the
    domain. The UI parses them with its own decimal library;
    [Number(x)] would lose precision the same way OCaml's
    {!Core.Decimal.of_float} does. *)

type t = {
  ts : int64;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type domain = Core.Candle.t

val of_domain : domain -> t

(** Read-model DTO for {!Core.Candle.t}.

    OHLCV as primitives: [ts] is a unix epoch-seconds int64,
    prices/volume are floats. No {!Core.Decimal.t} — precision
    is lost at the boundary, deliberately, since the UI works in
    float anyway. *)

type t = {
  ts : int64;
  open_ : float; [@key "open"]
  high : float;
  low : float;
  close : float;
  volume : float;
}
[@@deriving yojson]

type domain = Core.Candle.t

val of_domain : domain -> t

open Core

type t = {
  ts : int64;
  open_ : float; [@key "open"]
  high : float;
  low : float;
  close : float;
  volume : float;
}
[@@deriving yojson]

type domain = Candle.t

let of_domain (c : domain) : t =
  {
    ts = c.ts;
    open_ = Decimal.to_float c.open_;
    high = Decimal.to_float c.high;
    low = Decimal.to_float c.low;
    close = Decimal.to_float c.close;
    volume = Decimal.to_float c.volume;
  }

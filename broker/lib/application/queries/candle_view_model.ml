open Core

type t = {
  ts : int64;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type domain = Candle.t

let of_domain (c : domain) : t =
  {
    ts = c.ts;
    open_ = Decimal.to_string c.open_;
    high = Decimal.to_string c.high;
    low = Decimal.to_string c.low;
    close = Decimal.to_string c.close;
    volume = Decimal.to_string c.volume;
  }

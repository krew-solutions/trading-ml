open Core

type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
  price : string;
  fee : string;
  reason : string;
}
[@@deriving yojson]

type domain = Engine.Backtest.fill

let of_domain (f : domain) : t =
  {
    ts = f.ts;
    instrument = Instrument_view_model.of_domain f.instrument;
    side = Side.to_string f.side;
    quantity = Decimal.to_string f.quantity;
    price = Decimal.to_string f.price;
    fee = Decimal.to_string f.fee;
    reason = f.reason;
  }

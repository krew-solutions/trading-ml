type t = {
  ts : int64;
  open_ : Decimal.t;
  high : Decimal.t;
  low : Decimal.t;
  close : Decimal.t;
  volume : Decimal.t;
}

let make ~ts ~open_ ~high ~low ~close ~volume =
  if Decimal.compare low high > 0 then invalid_arg "Candle: low > high";
  if Decimal.compare open_ low < 0 || Decimal.compare open_ high > 0 then
    invalid_arg "Candle: open outside [low;high]";
  if Decimal.compare close low < 0 || Decimal.compare close high > 0 then
    invalid_arg "Candle: close outside [low;high]";
  if Decimal.is_negative volume then invalid_arg "Candle: negative volume";
  { ts; open_; high; low; close; volume }

let typical c =
  let three = Decimal.of_int 3 in
  Decimal.div (Decimal.add (Decimal.add c.high c.low) c.close) three

let median c =
  Decimal.div (Decimal.add c.high c.low) (Decimal.of_int 2)

let range c = Decimal.sub c.high c.low

let is_bull c = Decimal.compare c.close c.open_ > 0
let is_bear c = Decimal.compare c.close c.open_ < 0


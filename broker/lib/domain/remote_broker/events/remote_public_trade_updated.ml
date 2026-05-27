type t = {
  instrument : Core.Instrument.t;
  side : Core.Side.t option;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;
}

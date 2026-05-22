type t = {
  order_num : string;
  trade_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  ts : int64;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

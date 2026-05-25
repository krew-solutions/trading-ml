type t = {
  id : string;
  placement_id : Values.Placement_id.t;
  trade_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  ts : int64;
}

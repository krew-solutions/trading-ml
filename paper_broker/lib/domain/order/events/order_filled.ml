type t = {
  id : string;
  placement_id : Values.Placement_id.t;
  trade_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  fill_quantity : Decimal.t;
  fill_price : Decimal.t;
  fee : Decimal.t;
  new_total_filled : Decimal.t;
  fill_ts : int64;
}

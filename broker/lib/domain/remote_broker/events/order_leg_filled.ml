type t = {
  placement_id : int;
  trade_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  fill_quantity : Decimal.t;
  fill_price : Decimal.t;
  fee : Decimal.t;
  fill_ts : int64;
  new_total_filled : Decimal.t;
}

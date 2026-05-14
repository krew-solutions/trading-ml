type t = {
  id : string;
  client_order_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  created_ts : int64;
}

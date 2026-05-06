type t = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  previous_direction : Common.Direction.t;
  new_direction : Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}

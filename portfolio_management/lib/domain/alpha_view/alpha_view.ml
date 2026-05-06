module Events = Events

type t = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  direction : Common.Direction.t;
  strength : float;
  last_price : Decimal.t;
  last_observed_at : int64;
}

let empty ~alpha_source_id ~instrument =
  {
    alpha_source_id;
    instrument;
    direction = Common.Direction.Flat;
    strength = 0.0;
    last_price = Decimal.zero;
    last_observed_at = Int64.min_int;
  }

let clamp_strength s = Float.max 0.0 (Float.min 1.0 s)

let define t ~direction ~strength ~price ~occurred_at =
  if Int64.compare occurred_at t.last_observed_at <= 0 then (t, None)
  else
    let strength = clamp_strength strength in
    let updated =
      { t with direction; strength; last_price = price; last_observed_at = occurred_at }
    in
    if Common.Direction.equal direction t.direction then (updated, None)
    else
      let event : Events.Direction_changed.t =
        {
          alpha_source_id = t.alpha_source_id;
          instrument = t.instrument;
          previous_direction = t.direction;
          new_direction = direction;
          strength;
          price;
          occurred_at;
        }
      in
      (updated, Some event)

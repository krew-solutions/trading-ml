type t = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  previous_direction : Common.Direction.t;
  new_direction : Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}

let to_construction_intent (event : t) ~(book_id : Common.Book_id.t) :
    Common.Construction_intent.t =
  Common.Construction_intent.scalar ~book_id ~instrument:event.instrument
    ~direction:event.new_direction
    ~strength:(Common.Strength.of_float event.strength)
    ~source:(Common.Source.Alpha_view event.alpha_source_id)
    ~observed_at:event.occurred_at

type t = {
  book_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  total_quantity : Decimal.t;
}

let make ~book_id ~instrument ~side ~total_quantity =
  if Decimal.compare total_quantity Decimal.zero <= 0 then
    invalid_arg "Trade_intent.make: total_quantity must be positive";
  { book_id; instrument; side; total_quantity }

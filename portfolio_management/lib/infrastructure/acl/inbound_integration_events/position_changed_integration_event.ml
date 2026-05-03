type t = {
  book_id : string;
  instrument : Portfolio_management_queries.Instrument_view_model.t;
  delta_qty : string;
  new_qty : string;
  avg_price : string;
  occurred_at : string;
  cause : string;
}
[@@deriving yojson]

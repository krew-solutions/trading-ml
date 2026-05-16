include Target_position_view_model_t
include Target_position_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Portfolio_management.Common.Target_position.t

let of_domain (tp : domain) : t =
  {
    book_id = Portfolio_management.Common.Book_id.to_string tp.book_id;
    instrument = Instrument_view_model.of_domain tp.instrument;
    target_qty = Decimal.to_string tp.target_qty;
  }

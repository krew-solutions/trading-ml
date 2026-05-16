open Core
include Trade_intent_view_model_t
include Trade_intent_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Portfolio_management.Common.Trade_intent.t

let of_domain (i : domain) : t =
  {
    book_id = Portfolio_management.Common.Book_id.to_string i.book_id;
    instrument = Instrument_view_model.of_domain i.instrument;
    side = Side.to_string i.side;
    quantity = Decimal.to_string i.quantity;
  }

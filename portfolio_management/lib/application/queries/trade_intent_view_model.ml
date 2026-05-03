open Core

type t = {
  book_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
}
[@@deriving yojson]

type domain = Portfolio_management.Shared.Trade_intent.t

let of_domain (i : domain) : t =
  {
    book_id = Portfolio_management.Shared.Book_id.to_string i.book_id;
    instrument = Instrument_view_model.of_domain i.instrument;
    side = Side.to_string i.side;
    quantity = Decimal.to_string i.quantity;
  }

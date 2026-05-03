type t = { book_id : string; instrument : Instrument_view_model.t; target_qty : string }
[@@deriving yojson]

type domain = Portfolio_management.Shared.Target_position.t

let of_domain (tp : domain) : t =
  {
    book_id = Portfolio_management.Shared.Book_id.to_string tp.book_id;
    instrument = Instrument_view_model.of_domain tp.instrument;
    target_qty = Decimal.to_string tp.target_qty;
  }

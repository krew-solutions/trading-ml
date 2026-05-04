type change = {
  instrument : Portfolio_management_queries.Instrument_view_model.t;
  previous_qty : string;
  new_qty : string;
}
[@@deriving yojson]

type t = { book_id : string; source : string; proposed_at : int64; changed : change list }
[@@deriving yojson]

type domain = Portfolio_management.Target_portfolio.Events.Target_set.t

let of_change (c : Portfolio_management.Target_portfolio.Events.Target_set.change) :
    change =
  {
    instrument = Portfolio_management_queries.Instrument_view_model.of_domain c.instrument;
    previous_qty = Decimal.to_string c.previous_qty;
    new_qty = Decimal.to_string c.new_qty;
  }

let of_domain (ev : domain) : t =
  {
    book_id = Portfolio_management.Common.Book_id.to_string ev.book_id;
    source = ev.source;
    proposed_at = ev.proposed_at;
    changed = List.map of_change ev.changed;
  }

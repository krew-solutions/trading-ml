type t = {
  book_id : string;
  cash : string;
  positions : Actual_position_view_model.t list;
}
[@@deriving yojson]

type domain = Portfolio_management.Actual_portfolio.t

let of_domain (p : domain) : t =
  {
    book_id =
      Portfolio_management.Shared.Book_id.to_string
        (Portfolio_management.Actual_portfolio.book_id p);
    cash = Decimal.to_string (Portfolio_management.Actual_portfolio.cash p);
    positions =
      List.map Actual_position_view_model.of_domain
        (Portfolio_management.Actual_portfolio.positions p);
  }

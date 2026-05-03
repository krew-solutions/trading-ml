type t = { book_id : string; positions : Target_position_view_model.t list }
[@@deriving yojson]

type domain = Portfolio_management.Target_portfolio.t

let of_domain (p : domain) : t =
  {
    book_id =
      Portfolio_management.Shared.Book_id.to_string
        (Portfolio_management.Target_portfolio.book_id p);
    positions =
      List.map Target_position_view_model.of_domain
        (Portfolio_management.Target_portfolio.positions p);
  }

include Actual_portfolio_view_model_t
include Actual_portfolio_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Portfolio_management.Actual_portfolio.t

let of_domain (p : domain) : t =
  {
    book_id =
      Portfolio_management.Common.Book_id.to_string
        (Portfolio_management.Actual_portfolio.book_id p);
    cash = Decimal.to_string (Portfolio_management.Actual_portfolio.cash p);
    positions =
      List.map Actual_position_view_model.of_domain
        (Portfolio_management.Actual_portfolio.positions p);
  }

type t = {
  book_id : string;
  cash : string;
  positions : Position_snapshot_view_model.t list;
}
[@@deriving yojson]

type domain = Pre_trade_risk.Risk_view.t

let of_domain (v : domain) : t =
  {
    book_id = Pre_trade_risk.Common.Book_id.to_string (Pre_trade_risk.Risk_view.book_id v);
    cash = Decimal.to_string (Pre_trade_risk.Risk_view.cash v);
    positions =
      List.map Position_snapshot_view_model.of_domain
        (Pre_trade_risk.Risk_view.positions v);
  }

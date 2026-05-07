type t = {
  book_id : string;
  trades : Portfolio_management_queries.Trade_intent_view_model.t list;
  computed_at : string;
}
[@@deriving yojson]

type domain = Portfolio_management.Reconciliation.Events.Trades_planned.t

let of_domain (ev : domain) : t =
  {
    book_id = Portfolio_management.Common.Book_id.to_string ev.book_id;
    trades =
      List.map Portfolio_management_queries.Trade_intent_view_model.of_domain ev.trades;
    computed_at = Datetime.Iso8601.format ev.computed_at;
  }

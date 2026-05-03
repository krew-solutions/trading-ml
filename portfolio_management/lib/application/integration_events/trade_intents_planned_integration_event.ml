type t = {
  book_id : string;
  trades : Portfolio_management_queries.Trade_intent_view_model.t list;
  computed_at : int64;
}
[@@deriving yojson]

type domain = Portfolio_management.Reconciliation.Events.Trades_planned.t

let of_domain (ev : domain) : t =
  {
    book_id = Portfolio_management.Shared.Book_id.to_string ev.book_id;
    trades =
      List.map Portfolio_management_queries.Trade_intent_view_model.of_domain ev.trades;
    computed_at = ev.computed_at;
  }

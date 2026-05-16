type leg = {
  correlation_id : string;
  intent : Portfolio_management_view_models.Trade_intent_view_model.t;
}
[@@deriving yojson]

type t = { book_id : string; trades : leg list; computed_at : string } [@@deriving yojson]

type domain = Portfolio_management.Reconciliation.Events.Trades_planned.t

let of_domain (ev : domain) : t =
  {
    book_id = Portfolio_management.Common.Book_id.to_string ev.book_id;
    trades =
      List.map
        (fun i ->
          {
            correlation_id = Correlation_id.to_string (Correlation_id.generate ());
            intent = Portfolio_management_view_models.Trade_intent_view_model.of_domain i;
          })
        ev.trades;
    computed_at = Datetime.Iso8601.format ev.computed_at;
  }

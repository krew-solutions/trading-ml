type leg = {
  correlation_id : string;
  intent : Pre_trade_risk_external_view_models.Trade_intent_view_model.t;
}
[@@deriving yojson]

type t = { book_id : string; trades : leg list; computed_at : string } [@@deriving yojson]

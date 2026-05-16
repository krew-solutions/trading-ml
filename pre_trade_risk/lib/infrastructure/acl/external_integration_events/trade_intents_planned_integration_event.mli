(** pre_trade_risk-side mirror of PM's "trade intents planned"
    integration event. Structurally identical wire shape to
    {!Portfolio_management_integration_events.Trade_intents_planned_integration_event.t},
    owned locally so the BC stays bus-agnostic. *)

type leg = {
  correlation_id : string;
  intent : Pre_trade_risk_external_view_models.Trade_intent_view_model.t;
}
[@@deriving yojson]

type t = { book_id : string; trades : leg list; computed_at : string } [@@deriving yojson]

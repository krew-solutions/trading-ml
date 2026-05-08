(** Mirror of {!Pre_trade_risk_integration_events.Trade_intent_approved_integration_event.t}. *)

type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
}
[@@deriving yojson]

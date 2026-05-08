(** Inbound mirror of an upstream "position changed" integration
    event. Forward-looking: today Account does not yet publish this —
    the inbound branch is wired but unfed (mirrors PM's same-name
    handler, see ADR 0009 → Consequences). *)

type t = {
  book_id : string;
  instrument : Pre_trade_risk_inbound_queries.Instrument_view_model.t;
  delta_qty : string;
  new_qty : string;
  avg_price : string;
  occurred_at : string;
  cause : string;
}
[@@deriving yojson]

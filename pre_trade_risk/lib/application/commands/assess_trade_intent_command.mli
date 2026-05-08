(** Inbound command to the pre_trade_risk BC: "assess this proposed
    trade leg against the current Risk_view and the configured
    Risk_limits."

    Wire-format DTO — primitives + view-model DTOs, no
    {!Core.Instrument.t} / {!Core.Side.t} / {!Decimal.t}.

    Dispatched by the inbound ACL handler that subscribes to
    {!Portfolio_management_integration_events.Trade_intents_planned_integration_event};
    one command per leg, each carrying its own [correlation_id] minted
    by PM.

    Outcome flows back through {!Trade_intent_approved_integration_event}
    or {!Trade_intent_rejected_integration_event} on the BC's outbound
    bus; the {!Place_order_pm} Process Manager in [execution_management]
    keys both by [correlation_id]. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier — propagated verbatim from
        {!Portfolio_management_integration_events.Trade_intents_planned_integration_event.leg.correlation_id}.
        Echoed into the outbound IE so the saga routes the assessment
        back. *)
  book_id : string;
  symbol : string;
      (** Qualified instrument: [TICKER@MIC[/BOARD]] —
        {!Core.Instrument.of_qualified} round-trips it. *)
  side : string;  (** ["BUY"] | ["SELL"] (case-insensitive). *)
  quantity : string;  (** Decimal string accepted by {!Decimal.of_string}. *)
  price : string;
      (** Mark used for notional / exposure calculations. Synthesised by
        the inbound ACL handler from the most recent
        {!Risk_view.Values.Position_snapshot.avg_price} for the
        instrument, or [Decimal.zero] when the instrument is not
        currently held — in which case the gate rejects with
        ["zero price"], matching the original [Engine.Risk.check]
        contract. A future milestone will route real marks via a
        Bar_updated subscription. *)
}
[@@deriving yojson]

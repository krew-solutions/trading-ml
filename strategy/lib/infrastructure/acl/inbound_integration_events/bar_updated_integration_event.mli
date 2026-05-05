(** Strategy-side inbound mirror of the Broker BC's
    {!Broker_integration_events.Bar_updated_integration_event.t}.

    Structurally identical wire shape to the upstream event, but
    owned by Strategy so its consumers (Live_engine via the future
    handler) listen autonomously without importing types across the
    BC boundary. The bridge from Broker's outbound event to this
    mirror is an ACL adapter wired by the composition root via
    field-by-field copy.

    Idempotency: handlers MUST upsert by
    [(instrument, timeframe, bar.ts)]. Repeat publications of the
    same key (intra-bar updates from the venue, late-subscribe,
    replay, reconnect) are part of the contract. *)

type t = {
  instrument : Strategy_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  bar : Strategy_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]

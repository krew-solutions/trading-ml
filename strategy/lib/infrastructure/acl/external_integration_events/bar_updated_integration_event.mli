(** Strategy-side inbound mirror of the Broker BC's
    {!Broker_integration_events.Bar_updated_integration_event.t}.

    Structurally identical wire shape to the upstream event, but
    owned by Strategy so its consumers (Live_engine via the future
    handler) listen autonomously without importing types across the
    BC boundary. The bridge from Broker's outbound event to this
    mirror is an ACL adapter wired by the composition root via
    field-by-field copy.

    Idempotency: handlers MUST upsert by
    [(instrument, timeframe, candle.ts)]. Repeat publications of the
    same key (intra-bar updates from the venue, late-subscribe,
    replay, reconnect) are part of the contract.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}).
    The {b candle} field holds the pure OHLCV body without context. *)

type t = {
  instrument : Strategy_external_view_models.Instrument_view_model.t;
  timeframe : string;
  candle : Strategy_external_view_models.Candle_view_model.t;
}
[@@deriving yojson]

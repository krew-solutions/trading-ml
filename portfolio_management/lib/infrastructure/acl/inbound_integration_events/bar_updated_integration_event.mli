(** PM-side inbound mirror of the Broker BC's
    {!Broker_integration_events.Bar_updated_integration_event.t}.

    Structurally identical wire shape to the upstream event, but
    owned by PM so its consumer
    ({!Bar_updated_integration_event_handler}, which drives
    pair-mean-reversion policies) listens autonomously without
    importing types across the BC boundary. The bridge from
    Broker's outbound topic to this mirror is a deserializer at
    {!Bus.consumer} time — JSON wire is the only contract.

    Idempotency: handlers MUST upsert by
    [(instrument, timeframe, candle.ts)]. Repeat publications of the
    same key (intra-bar updates from the venue, late-subscribe,
    replay, reconnect) are part of the contract.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}).
    The {b candle} field holds the pure OHLCV body without context. *)

type t = {
  instrument : Portfolio_management_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  candle : Portfolio_management_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]

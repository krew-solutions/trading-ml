(** paper_broker-side inbound mirror of the Broker BC's
    [Bar_updated_integration_event.t].

    Structurally identical wire shape to the upstream event, but
    owned by paper_broker so its consumer
    ({!Bar_updated_integration_event_handler}) listens
    autonomously without importing types across the BC boundary.
    The bridge from broker's outbound topic to this mirror is a
    deserializer at {!Bus.consumer} time — JSON wire is the only
    cross-BC contract.

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}).
    The {b candle} field holds the pure OHLCV body without
    context. *)

type t = {
  instrument : Paper_broker_inbound_queries.Instrument_view_model.t;
  timeframe : string;
  candle : Paper_broker_inbound_queries.Candle_view_model.t;
}
[@@deriving yojson]

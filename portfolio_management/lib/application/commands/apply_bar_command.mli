(** Inbound command to the Portfolio Management BC: "advance every
    pair-mean-reversion state registered for [instrument] with the
    supplied bar."

    Wire-format DTO — primitives only, no domain values. [instrument]
    is the qualified [TICKER@MIC[/BOARD]] form parsed by the handler;
    OHLCV fields on [candle] are decimal strings (bit-exact roundtrip
    with [Decimal.to_string]).

    Naming: a {b bar} = ({i instrument}, {i timeframe}, {i candle}) —
    the contextualised market-data observation. The {b candle} field
    holds the pure OHLCV body without context.

    Triggered by:
      - the inbound [Bar_updated_integration_event] handler translating
        a broker-published bar (single production caller today);
      - future external entries (CLI replay, backtest harness) that
        want to drive pair-mr policies without going through the bus. *)

type candle_dto = {
  ts : string;  (** ISO-8601 *)
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type t = {
  instrument : string;  (** [TICKER@MIC[/BOARD]] *)
  timeframe : string;
  candle : candle_dto;
}
[@@deriving yojson]

(** Domain event — the remote broker delivered a fresh bar for
    [(instrument, timeframe)]. Recognised by the ACL adapter
    from the broker's wire frame (Finam WS bar update, BCS WS
    candle payload, REST poll tick) and emitted into
    [Remote_broker.Events].

    The bar is a venue-originated fact (price discovery happens
    at the venue; the broker relays). Carried verbatim — the
    candle is the venue's authoritative shape for the period;
    the adapter only normalises wire encoding (timestamps,
    decimals), it does not aggregate or re-compute. *)

type t = {
  instrument : Core.Instrument.t;
  timeframe : Core.Timeframe.t;
  candle : Core.Candle.t;
}

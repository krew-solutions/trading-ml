open Core

(** BCS Trade API WebSocket — multiplexed [/market-data/ws]
    endpoint envelope-level dispatcher.

    Reference: saved copy of the official docs page
    "Последняя-свеча-БКС-Торговое-API.html" (section
    «Описание протокола»).

    BCS publishes only public market-data through this channel
    (candles). Personal-account fills, order state, and book
    updates are not available here; the broker BC handles
    those via REST polling (see {!Factory.bcs_polling_setup}).

    Outbound subscribe / unsubscribe envelopes live under
    {!Requests}; per-channel inbound event parsers live under
    {!Events}. This module owns the envelope-level sum type
    and the dispatcher that picks the right parser. *)

module Events = Events
(** Channel parsers (inbound). *)

module Requests = Requests
(** Channel subscribe/unsubscribe encoders (outbound). *)

(** Top-level decoded inbound event variants. *)
type event =
  | Candle_ev of Events.Candle.t
  | Subscribe_ack of Events.Subscribe_ack.t
  | Error_ev of Events.Error.t
  | Other of Yojson.Safe.t
      (** Envelope shape the dispatcher doesn't recognise — for
          example a Heartbeat the server may push. Carries the
          raw JSON so callers can log it or extend recognition. *)

val event_of_json : Yojson.Safe.t -> event
(** Reads the [responseType] / [errors] fields and delegates
    payload parsing to the matching {!Events} module. Never
    raises — malformed envelopes fall through to [Other]. *)

val timeframe_of_string : string -> Timeframe.t option
(** Reverse of {!Rest.timeframe_wire}. Surfaced here so the
    per-channel parsers in {!Events} share one source of truth
    for the wire-string mapping (M1, M5, ... MN). *)

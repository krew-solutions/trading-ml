(** Finam async-api WebSocket: envelope-level dispatcher.

    Reference: [specs/asyncapi/asyncapi-v1.0.0.yaml] in the
    [finam-trade-api] mirror.

    Wire format (client → server) is a single envelope:
    {[
      { "action": "SUBSCRIBE",         (* | UNSUBSCRIBE | UNSUBSCRIBE_ALL *)
        "type":   "BARS",              (* | ORDER_BOOK | QUOTES | TRADES | ACCOUNT *)
        "data":   { ... },             (* channel-specific *)
        "token":  "<JWT>" }
    ]}

    Server → client envelope:
    {[
      { "type": "DATA",                (* | ERROR | EVENT *)
        "subscription_type": "BARS",
        "subscription_key":  "<opt>",
        "timestamp": 1700000000,
        "payload":  { ... } }
    ]}

    Outbound request encoders live under {!Requests}; per-channel
    inbound event parsers + handlers live under {!Events}. This
    module owns the envelope-level sum type and the dispatcher
    that picks the right channel parser. *)

module Events = Events
(** Channel parsers + handlers (inbound). *)

module Requests = Requests
(** Channel subscribe/unsubscribe encoders (outbound). *)

module Payload = Payload
(** Shared payload-unwrap helper used by channel parsers. *)

(** Top-level decoded inbound event variants. *)
type event =
  | Bars of Events.Bars.t
  | Quote of Events.Quote.t
  | Trades of Events.Trade.update list
  | Error_ev of Events.Error.t
  | Lifecycle of Events.Lifecycle.t
  | Other of Yojson.Safe.t
      (** Envelope shape the dispatcher doesn't recognise, or a
          DATA envelope on a subscription_type without a parser
          (e.g. ORDER_BOOK). Carries the raw JSON so callers can
          log it or extend recognition. *)

val event_of_json : Yojson.Safe.t -> event
(** Reads the [type] / [subscription_type] fields and delegates
    payload parsing to the matching [Events.*] module. Never
    raises — malformed envelopes fall through to [Other]. *)

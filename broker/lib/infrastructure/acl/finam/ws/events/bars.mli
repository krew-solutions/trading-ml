(** Inbound BARS event: a batch of candles for one instrument on
    one timeframe.

    The envelope's [subscription_key] (formatted
    ["<TICKER>@<MIC>:<TIMEFRAME>"]) is the authoritative source for
    both instrument and timeframe. Finam's AsyncAPI spec marks the
    field optional ("если применяется"), but live observation
    against [api.finam.ru/ws] on 2026-05-22 confirmed it is present
    on every BARS DATA envelope and is server-synthesised — the
    server silently ignores any value the client tries to supply
    in its SUBSCRIBE request. The parser therefore relies on the
    envelope-level key rather than guessing from the inner payload. *)

open Core

type t = { instrument : Instrument.t; timeframe : Timeframe.t; bars : Candle.t list }

val parse : Yojson.Safe.t -> t
(** Parses the BARS payload from a full DATA envelope. Raises
    [Invalid_argument] when [subscription_key] is missing or
    unparseable — the WS bridge's top-level decode-fail handler
    logs and drops the frame, surfacing the contract drift loudly
    rather than silently fabricating bars. *)

val to_domain : t -> Broker_domain.Remote_broker.Events.Remote_bar_updated.t list
(** Fans the batch into one {!Remote_bar_updated} domain event per
    candle, carrying the [instrument] and [timeframe] resolved by
    the parser. *)

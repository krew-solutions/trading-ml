(** Inbound command to the Broker BC: "I want bars for this
    [(instrument, timeframe)] flowing on the bus while I hold this
    subscription open."

    Wire-format DTO — primitives only ([symbol], [timeframe] as
    strings), no {!Core.Instrument.t} / {!Core.Timeframe.t}. The
    atd source is the single source of truth for the wire shape;
    atdgen emits the typed record (_t) and JSON codec (_j)
    consumed by the InMemory bus today and a real (network) bus
    tomorrow with byte-identical framing.

    Fire-and-forget; no correlation id, no response IE. The only
    observable effect is bars appearing on [broker.bar-updated]
    for the key while interest is held. The matching
    {!Unwatch_bars_command} releases this caller's interest;
    other callers' watches on the same key are unaffected
    (refcount on the adapter side). *)

include module type of Watch_bars_command_t
include module type of Watch_bars_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

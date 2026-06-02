(** Inbound command to the order_flow BC: "I want footprints for this
    [(instrument, boundary)] being built and published on the bus while I
    hold this subscription open."

    Wire-format DTO — primitives only ([symbol], [boundary] as strings),
    no {!Core.Instrument.t} / {!Order_flow.Footprint.Values.Bar_boundary.t}.
    The atd source is the single source of truth for the wire shape;
    atdgen emits the typed record (_t) and JSON codec (_j) consumed by the
    InMemory bus today and a real (network) bus tomorrow with
    byte-identical framing.

    The footprint analogue of {!Broker}'s watch_bars_command: it is what
    lets a UI subscribe to a footprint boundary of its own choosing rather
    than the single boundary the operator configured. Fire-and-forget; no
    correlation id, no response IE. The matching
    {!Unwatch_footprints_command} releases this caller's interest; other
    callers' watches on the same key are unaffected (refcount in the BC). *)

include module type of Watch_footprints_command_t
include module type of Watch_footprints_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

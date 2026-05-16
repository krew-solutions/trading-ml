(** Inbound command to the Broker BC: "submit this order to the
    upstream broker."

    Wire-format DTO — primitives + view-model DTOs, no
    {!Core.Instrument.t} / {!Core.Side.t} / {!Decimal.t}.
    The atd source is the single source of truth for the wire
    shape; atdgen emits the typed record (_t) and JSON codec (_j)
    consumed by the InMemory bus today and a real (network) bus
    tomorrow with byte-identical framing.

    [placement_id] is the cross-BC saga key — created by Account
    when reserving cash / quantity, propagated by the inbound
    HTTP layer into this command, echoed back by every
    {!Broker_integration_events} variant the handler emits. The
    upstream broker's wire identity (BCS dashed-UUID, Finam
    letters/digits/space, etc.) is minted privately inside the
    selected ACL adapter when it implements
    [Broker.place_order_by_placement_id] and never crosses the
    port boundary — callers neither see nor supply it. *)

include module type of Submit_order_command_t
include module type of Submit_order_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

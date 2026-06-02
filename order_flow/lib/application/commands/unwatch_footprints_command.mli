(** Inbound command to the order_flow BC: the release counterpart of
    {!Watch_footprints_command.t}. "I no longer need footprints for this
    [(instrument, boundary)]."

    Wire-format DTO — primitives only ([symbol], [boundary] as strings).
    The atd source is the single source of truth for the wire shape.
    Fire-and-forget; the BC-side refcount stops aggregating the boundary
    only on the 1->0 transition, leaving other callers' watches on the
    same key untouched. An unwatch with no matching prior watch is a
    benign no-op. *)

include module type of Unwatch_footprints_command_t
include module type of Unwatch_footprints_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

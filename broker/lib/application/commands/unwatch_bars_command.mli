(** Inbound command to the Broker BC: counterpart to
    {!Watch_bars_command}. "I am releasing my interest in this
    [(instrument, timeframe)] bar feed; the upstream venue feed
    may close iff no other caller still holds it."

    Wire-format DTO — primitives only ([symbol], [timeframe] as
    strings). The atd source is the single source of truth for
    the wire shape; atdgen emits the typed record (_t) and JSON
    codec (_j).

    Fire-and-forget; no correlation id, no response IE. The
    adapter decrements its per-key refcount; the upstream
    UNSUBSCRIBE only goes out at the 1→0 transition. *)

include module type of Unwatch_bars_command_t
include module type of Unwatch_bars_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

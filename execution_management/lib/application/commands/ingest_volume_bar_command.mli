(** Command: a volume bar arrived from the volume-feed adapter
    that the POV strategy on this ticket consumes. The volume
    feed is a deferred infrastructure (PR4b ships a [Disabled]
    adapter), so this command is rarely fired today; it exists
    so POV's interface is concrete from day one. *)

type t = { ticket_id : int; bar_ts : int64; bar_volume : string  (** Decimal string. *) }

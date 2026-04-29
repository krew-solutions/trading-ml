(** Integration event: the broker could not be reached, or the
    upstream returned a transport-level error (timeout, 5xx, TLS
    failure, malformed response). Indistinguishable from
    {!Order_rejected} at the choreography level — both compensate
    the reservation — but kept as a separate type so that SSE and
    audit can surface the cause distinctly and so subscribers that
    care about transport health (retry policies, alerting) can
    listen to this channel only.

    [reservation_id] echoes the saga key for compensation lookup.
    [reason] is a free-form string from the underlying exception
    or transport error. *)

type t = { reservation_id : int; reason : string } [@@deriving yojson]

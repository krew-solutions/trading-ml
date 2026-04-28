(** Broker-agnostic ISO-8601 → unix epoch seconds (UTC "Z" suffix).

    Pure date parsing, not tied to any wire format. Shared across
    callers that need to turn a textual date into an int64 —
    broker ACL adapters parsing timestamps in JSON, and CLI
    scripts parsing [--from] / [--to] arguments. *)

val parse : string -> int64
(** Parses an ISO-8601 datetime string like
    [2024-01-15T13:45:00Z] into a UTC epoch-seconds int64.

    Falls back to parsing the input as a plain int64 if the date
    pattern doesn't match; returns [0L] on total failure. *)

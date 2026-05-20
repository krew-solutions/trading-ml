(** Logs an inbound ERROR envelope at warning level. The
    upstream connection layer reacts to disconnects on its
    own — ERROR envelopes are informational at this layer. *)

val handle : Error.t -> unit

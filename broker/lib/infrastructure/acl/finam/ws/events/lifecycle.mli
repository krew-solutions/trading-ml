(** Inbound EVENT envelope: connection-lifecycle notification
    (handshake / heartbeat / disconnect reason). *)

type t = { event : string; code : int; reason : string }

val parse : Yojson.Safe.t -> t

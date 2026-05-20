(** Inbound ERROR envelope. *)

type t = { code : int; type_ : string; message : string }

val parse : Yojson.Safe.t -> t

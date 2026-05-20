(** Inbound error envelope — BCS surfaces protocol-level failures
    by setting a non-empty [errors] array on otherwise normal-looking
    responses. *)

type t = { code : string; message : string }

(** Extracts the first entry of the [errors] array if present.
    [None] means the envelope is not an error. *)
val parse : Yojson.Safe.t -> t option

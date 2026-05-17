(** Error union shared across all OrderTicket-aggregate command
    handlers and workflows. *)

type t =
  | Ticket_not_found of int
      (** No ticket with this id is in the store. Late or
          ill-correlated apply_* / cancel command. *)
  | Invalid_payload of string
      (** Wire-shape parse failure (malformed decimal, unknown
          side / kind / tif, non-positive id). *)
  | Domain_violation of string
      (** The domain rejected the operation (e.g. fill quantity
          would push past total; should not happen in
          well-behaved pipelines but caught at the boundary). *)

val to_string : t -> string

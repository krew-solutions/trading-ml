(** Contract implemented by each [*_view_model.ml] in this library.
    Mirrors the equivalent in [account/lib/application/queries/]:
    DTO + projection from the domain live in the same module.

    Read-side contract only: [of_domain] projects a valid domain
    value into a primitive-typed DTO. The inverse direction is the
    concern of the commands layer. *)

module type S = sig
  type t
  (** DTO: primitive-typed, serialisable. *)

  type domain
  (** Corresponding domain value. *)

  val yojson_of_t : t -> Yojson.Safe.t
  val t_of_yojson : Yojson.Safe.t -> t

  val of_domain : domain -> t
  (** Total projection. *)
end

(** Contract implemented by each [*_view_model.ml] in this
    library. Inspired by the DTO-module pattern from Scott
    Wlaschin's "Domain Modeling Made Functional": DTO type and
    projection from the domain live in the same module.

    Read-side contract only: [of_domain] projects a valid
    domain value into a primitive-typed DTO. The inverse
    direction ([to_domain] with validation) is the concern of a
    separate [commands/] layer and will use an accumulating
    [Rop.t] result, not a plain function. *)

module type S = sig
  type t
  (** DTO: primitive-typed, serializable. *)

  type domain
  (** Corresponding domain value. *)

  val yojson_of_t : t -> Yojson.Safe.t
  val t_of_yojson : Yojson.Safe.t -> t

  val of_domain : domain -> t
  (** Total projection. A valid [domain] always produces a
      valid [t]; precision loss ([Decimal.t] → [float]) is
      accepted as the cost of crossing the boundary into
      primitives. *)
end

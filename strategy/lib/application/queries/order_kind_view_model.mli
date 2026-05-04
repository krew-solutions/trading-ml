(** Read-model DTO for {!Common.Order.kind}.

    Flattened discriminated union: [type_] is the tag
    ([MARKET] / [LIMIT] / [STOP] / [STOP_LIMIT]) and the
    kind-specific price fields are optional — present only for
    the kinds that need them. *)

type t = {
  type_ : string; [@key "type"]
  price : string option;
      (** Decimal string accepted by {!Decimal.of_string}.
          [Some] for [LIMIT] / [STOP], [None] for [MARKET] / [STOP_LIMIT]. *)
  stop_price : string option;  (** [Some] for [STOP_LIMIT], [None] otherwise. *)
  limit_price : string option;  (** [Some] for [STOP_LIMIT], [None] otherwise. *)
}
[@@deriving yojson]

type domain = Common.Order.kind

val of_domain : domain -> t

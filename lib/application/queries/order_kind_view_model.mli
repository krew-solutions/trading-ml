(** Read-model DTO for {!Core.Order.kind}.

    Flattened discriminated union: [type_] is the tag
    ([MARKET] / [LIMIT] / [STOP] / [STOP_LIMIT]) and the
    kind-specific price fields are optional — present only for
    the kinds that need them. *)

type t = {
  type_ : string; [@key "type"]
  price : float option;
  stop_price : float option;
  limit_price : float option;
}
[@@deriving yojson]

type domain = Core.Order.kind

val of_domain : domain -> t

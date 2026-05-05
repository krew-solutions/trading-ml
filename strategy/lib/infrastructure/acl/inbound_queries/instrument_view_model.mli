(** Strategy-side inbound DTO mirror of an instrument view model.

    Structural-only: identifies the four wire fields. No
    [of_domain] / [type domain] — this DTO is consumed (deserialized
    or field-copied from an upstream BC's outbound DTO at the
    composition root), not produced from a strategy domain value. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

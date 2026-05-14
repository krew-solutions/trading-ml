(** Outbound view-model mirror of {!Core.Instrument.t}. Used by the
    BC's outbound queries / integration events. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

type domain = Core.Instrument.t

val of_domain : domain -> t

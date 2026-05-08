(** Inbound DTO mirror of an instrument view model. Structural-only;
    no [of_domain]. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

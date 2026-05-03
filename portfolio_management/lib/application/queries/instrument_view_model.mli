(** Read-model DTO for {!Core.Instrument.t}.

    Local copy of the same VM in the strategy / account BCs: kept
    independent so that [portfolio_management_queries] doesn't depend
    on the other BCs and the BC graph stays acyclic. The on-wire JSON
    shape is identical between the three. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

type domain = Core.Instrument.t

val of_domain : domain -> t

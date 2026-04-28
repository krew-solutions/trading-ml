(** Read-model DTO for {!Core.Instrument.t}.

    Primitive-typed: the four identity fields projected as plain
    strings. Carries no domain invariants — this is an outbound
    projection only; reconstructing a valid {!Core.Instrument.t}
    from a DTO is the concern of the future [commands/] layer.

    Duplicate of the same VM in the strategy BC's queries: kept
    independent so that [account_queries] doesn't depend on the
    strategy library and the BC graph stays acyclic. The on-wire
    JSON shape is identical between the two. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

type domain = Core.Instrument.t

val of_domain : domain -> t

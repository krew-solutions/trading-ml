(** Account-side inbound DTO mirror of an instrument view model.

    Structural-only: identifies the four wire fields. No
    [of_domain] / [type domain] — this DTO is consumed (deserialized
    from an upstream BC's outbound JSON), not produced from an Account
    domain value. Kept independent of {!Account_queries.Instrument_view_model}
    (Account's own outbound projection) so that the inbound and outbound
    sides of the wire can evolve their schemas independently. *)

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

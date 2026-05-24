(** Integration event: a partial fill drew the reservation down,
    leaving an unfilled remainder still earmarked.

    Published by {!Commit_fill_command_workflow} when
    {!Account.Portfolio.commit_fill} returns
    [Ok (_, Drawn_down _)]. The terminal draw is announced by
    {!Reservation_filled_integration_event} instead — consumers
    receive one or many [reservation-drawn-down] events
    followed by exactly one [reservation-filled] per
    reservation lifecycle.

    Carries the full transactional effect — both the post-fill
    position / cash and the residual reserved snapshot — in
    one atomic payload, so consumers cannot observe a state
    that violates [equity = cash + Σ qty × mark]. Same
    accounting-identity argument as
    {!Reservation_filled_integration_event}.

    Subscribed by [pre_trade_risk]'s drawdown circuit
    (ADR 0021) and any consumer projecting per-fill activity.

    DTO-shaped: primitives + nested instrument view model, no
    domain values. Decimals on the wire as canonical strings
    (ADR 0007). See ADR 0028 for the progressive-drawdown
    contract this event closes. *)

include module type of Reservation_drawn_down_integration_event_t

include module type of Reservation_drawn_down_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Account.Portfolio.Events.Reservation_drawn_down.t

val of_domain : correlation_id:string -> domain -> t

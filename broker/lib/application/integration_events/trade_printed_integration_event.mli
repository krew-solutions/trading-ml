(** Integration event: one public-tape trade observed for an instrument.

    Published by the broker BC from its venue trade stream (Finam
    INSTRUMENT_TRADES / BCS dataType:2 / Alor AllTrades). Distinct from
    {!Trade_executed_integration_event}, which reports fills of this
    account's own orders (ADR 0029) and carries saga metadata; a tape
    print is venue data with no order linkage, consumed by the
    order_flow BC for footprint analysis (ADR 0032).

    [aggressor] is BUY | SELL | UNSPECIFIED — the venue-reported
    initiator, normalised here from the domain's [Side.t option]. The
    BUY/SELL mapping rests on MOEX convention (ADR 0032 caveat); this
    [of_domain] is the single flip-point if it proves inverted.

    DTO-shaped: primitives only, no domain values. *)

include module type of Trade_printed_integration_event_t
include module type of Trade_printed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t

val of_domain : domain -> t

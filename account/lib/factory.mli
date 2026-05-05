(** Account BC composition root.

    {!build} wires up the entire Account-side runtime against a
    pre-constructed {!Bus.bus}: outbound producers, internal mutable
    state, workflow ports, and inbound subscriptions for cross-BC
    compensation. It returns the minimal external surface the
    Trading-host needs from Account — today that is just the HTTP
    route handler.

    {b Why a factory.} Each BC owns its own composition step. The
    monolithic [bin/main.ml] still constructs the bus and stitches
    BCs together, but it no longer knows how Account computes margin,
    counts reservations, or names its inbound consumer groups. When
    Account is later extracted into its own service, this same
    function moves verbatim into [account-service/main.ml] — the
    only difference will be that the bus is a Kafka adapter, not
    in-memory. *)

open Core

type t = { http_handler : Inbound_http.Route.handler }
(** External surface of an Account instance. The HTTP route handler
    is registered by the Trading-host server. Workflow ports
    ([dispatch_reserve], [dispatch_release]), the mutable
    [portfolio_ref], and the compensation subscriptions are
    deliberately not exposed — they are Account-internal. *)

val build :
  bus:Bus.bus ->
  initial_cash:Decimal.t ->
  market_price:(instrument:Instrument.t -> Decimal.t) ->
  t
(** Construct the Account runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by Account's outbound and inbound
    URIs (today: [account.amount-reserved] /
    [account.reservation-released] / [account.reservation-rejected]
    outbound; [broker.order-rejected] / [broker.order-unreachable]
    inbound).

    [initial_cash] seeds the Account portfolio.

    [market_price] is the upstream-mark port. Account does not
    construct it because it must not know which broker is running;
    the Trading-host supplies a closure (typically wrapping
    [Broker.bars]). For [Market] orders this is the cash-impact
    reference at reservation time; [Limit] / [Stop] orders use
    their own price. *)

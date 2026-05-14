(** Portfolio Management BC composition root.

    {!build} stands up the entire PM-side runtime against a
    pre-constructed {!Bus.bus}: in-memory per-book registries,
    outbound producers, all command dispatch ports, and the inbound
    subscription on Account's [Reservation_filled] integration event.

    {b State of integration today.} PM's external surfaces are
    partially wired:
    - The inbound subscription on [account.reservation-filled] is
      live: incoming fills are committed atomically into
      [Actual_portfolio] via [Commit_actual_fill_command].
    - There is no HTTP / scheduler / Strategy → PM bridge today,
      so [Set_target] / [Reconcile] / [Define_alpha_view] dispatch
      ports are constructed but not invoked.

    {b Why a factory.} See {!Account_factory.Factory} for the
    rationale — same pattern, same future-distributed migration
    story. *)

type t = { http_handler : Inbound_http.Route.handler }
(** Same shape as {!Account_factory.Factory.t} for uniformity across
    BC factories. The [http_handler] is currently a stub from
    {!Portfolio_management_inbound_http.Http.make_handler} that
    returns [None] for every request. When PM gains real REST
    routes, [Http.make_handler] will start receiving the dispatch
    ports and pattern-matching against [(meth, path)] — the field
    in [t] does not change. *)

val build : bus:Bus.bus -> now:(unit -> int64) -> t
(** Construct the PM runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by PM's outbound URIs
    ([pm.target-portfolio-updated], [pm.trade-intents-planned]) and
    inbound URI ([account.reservation-filled]).

    [now] supplies ambient time (epoch seconds), used by the
    [Reservation_filled] ACL to stamp [occurred_at] on the
    derived domain commit. See ADR 0013. *)

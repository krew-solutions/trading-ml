(** Portfolio Management BC composition root.

    {!build} stands up the entire PM-side runtime against a
    pre-constructed {!Bus.bus}: in-memory per-book registries,
    outbound producers, all command dispatch ports, and inbound
    subscriptions for cross-BC events from Account.

    {b State of integration today.} PM's external surfaces are not
    yet wired:
    - The Account BC does not publish [Cash_changed] /
      [Position_changed] yet, so PM's inbound subscriptions are
      registered but inert.
    - There is no HTTP / scheduler / Strategy → PM bridge today,
      so [Set_target] / [Reconcile] / [Define_alpha_view] dispatch
      ports are constructed but not invoked.
    [build] still wires up everything end-to-end so the BC is
    typecheck-validated as a working composition; trafic just
    isn't there yet.

    {b Why a factory.} See
    {!Account_factory.Factory} for the rationale —
    same pattern, same future-distributed migration story. *)

type t = { http_handler : Inbound_http.Route.handler }
(** Same shape as {!Account_factory.Factory.t} for uniformity across
    BC factories. The [http_handler] is currently a stub from
    {!Portfolio_management_inbound_http.Http.make_handler} that
    returns [None] for every request. When PM gains real REST
    routes, [Http.make_handler] will start receiving the dispatch
    ports and pattern-matching against [(meth, path)] — the field
    in [t] does not change. *)

val build : bus:Bus.bus -> t
(** Construct the PM runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by PM's outbound URIs ([pm.target-
    portfolio-updated], [pm.trade-intents-planned]) and inbound
    URIs ([account.cash-changed], [account.position-changed]). *)

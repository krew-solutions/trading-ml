(** PM inbound HTTP routes.

    Today a stub: {!make_handler} returns a route handler that
    answers [None] for every request, meaning PM contributes
    nothing to the HTTP surface. The stub is wired up so that
    {!Factory.t} can carry an [http_handler] field uniformly with
    the other BC factories.

    When PM gains real routes (Set_target / Reconcile /
    Define_alpha_view via REST), {!make_handler} will gain
    [~dispatch_*] port parameters, parse wire-payloads into
    command DTOs, and pattern-match against [(meth, path)] to
    return [Some response] for handled routes — without any
    change required in {!Factory}. *)

val make_handler : unit -> Inbound_http.Route.handler

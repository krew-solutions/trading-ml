(** Strategy inbound HTTP routes.

    Today a stub: {!make_handler} returns a route handler that
    answers [None] for every request. Strategy contributes nothing
    to the HTTP surface yet — engine telemetry / strategy controls
    are future work. The stub is wired so that {!Factory.t} can
    carry an [http_handler] field uniformly with the other BC
    factories. *)

val make_handler : unit -> Inbound_http.Route.handler

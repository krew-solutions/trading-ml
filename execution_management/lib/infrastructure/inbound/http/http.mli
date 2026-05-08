(** Execution_management inbound HTTP routes. Stub today — every
    request returns [None]. Future surfaces: kill-switch reset
    endpoint, saga-progress SSE channel filtered by correlation_id. *)

val make_handler : unit -> Inbound_http.Route.handler

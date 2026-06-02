(** Broker BC inbound HTTP routes.

    Exposes a single route today:
      GET /api/exchanges  list venues (MIC codes) this broker can
                          route to, plus [default_board] — the board this
                          broker tags onto instrument identities (BCS/Alor
                          "TQBR"), so the UI can subscribe with the
                          board-qualified id by default.

    Order operations are no longer surfaced over HTTP. They flow
    through the bus as placement-keyed commands; venue-native
    handles are private to each ACL adapter and not addressable
    from outside the BC.

    The handler is built once at the composition root with a
    {!Broker.client} port and registered with the core HTTP server
    through {!Inbound_http.Route.handler}. Routes outside this set
    return [None], letting the server's other handlers try. *)

val make_handler :
  broker:Broker.client -> default_board:string option -> Inbound_http.Route.handler

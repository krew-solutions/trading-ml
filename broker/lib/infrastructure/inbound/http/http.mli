(** Broker BC inbound HTTP routes.

    Exposes a single route today:
      GET /api/exchanges  list venues (MIC codes) this broker can
                          route to.

    Order operations are no longer surfaced over HTTP. They flow
    through the bus as placement-keyed commands; venue-native
    handles are private to each ACL adapter and not addressable
    from outside the BC.

    The handler is built once at the composition root with a
    {!Broker.client} port and registered with the core HTTP server
    through {!Inbound_http.Route.handler}. Routes outside this set
    return [None], letting the server's other handlers try. *)

val make_handler : broker:Broker.client -> Inbound_http.Route.handler

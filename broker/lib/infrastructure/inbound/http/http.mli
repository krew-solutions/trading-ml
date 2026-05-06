(** Broker BC inbound HTTP routes.

    Today exposes:
      GET    /api/orders                    list all orders on the
                                             broker.
      GET    /api/orders/<client_order_id>  fetch one order by
                                             caller-controlled id.
      DELETE /api/orders/<client_order_id>  request cancellation by id.
      GET    /api/exchanges                 list venues (MIC codes)
                                             this broker can route to.

    The handler is built once at the composition root with a
    {!Broker.client} port and registered with the core HTTP server
    through {!Inbound_http.Route.handler}. Routes outside this set
    return [None], letting the server's other handlers try. *)

val make_handler : broker:Broker.client -> Inbound_http.Route.handler

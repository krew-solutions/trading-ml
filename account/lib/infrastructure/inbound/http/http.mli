(** Account BC inbound HTTP routes.

    Today exposes:
      POST /api/orders   start an order-placement saga by dispatching
                         {!Account_commands.Reserve_command.t} on the
                         provided command bus. The HTTP response is a
                         202 Accepted; the actual outcome (reservation
                         accepted/rejected, broker accepted/rejected)
                         arrives asynchronously over integration-event
                         buses and is published to clients via SSE.

    The handler is built once at the composition root and registered
    with the core HTTP server through {!Inbound_http.Route.handler}. *)

open Core

type market_price_port = instrument:Instrument.t -> Decimal.t
(** Latest mark used to compute the cash earmark for a [Market]
    order. The Account BC does not query upstream for it — the
    composition root supplies a closure that knows how to fetch a
    price (typically over the configured broker), so Account stays
    unaware of broker types. Returns [Decimal.t] for bit-exact
    round-trip with the on-wire decimal-string representation. *)

val make_handler :
  dispatch_reserve:(Account_commands.Reserve_command.t -> unit) ->
  market_price:market_price_port ->
  Inbound_http.Route.handler

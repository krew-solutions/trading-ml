(** Trading-host inbound composition.

    Two-step contract:

    - {!build} assembles the SSE registry and wires every bus
      subscription the inbound HTTP surface depends on:

      - [broker.bar-updated] → ACL decode → registry push;
      - account / broker order-event topics → publish on the
        [order] SSE channel via {!Server.Publish_order_events}.

    - {!serve} drives the HTTP listener against the built handle.

    Subscription handles are owned by the bus for the lifetime
    of the process; this module doesn't return them. The SSE
    registry itself is intentionally opaque — its only
    legitimate consumer is {!serve}, which runs the cohttp
    listener and routes SSE traffic through it. *)

type t

val build :
  bus:Bus.bus -> bar_subscription:Server_application_ports.Bar_subscription.t -> t

val serve :
  t ->
  ?bc_handlers:Inbound_http.Route.handler list ->
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  port:int ->
  broker:Broker.client ->
  unit ->
  unit

(** Trading-host inbound composition.

    Two-step contract:

    - {!build} assembles the SSE registry and wires every bus
      subscription the inbound HTTP surface depends on:

      - [broker.bar-updated] → ACL decode → registry push;
      - account / broker order-event topics → publish on the
        [order] SSE channel via {!Server.Publish_order_events}.

    - {!serve} drives the HTTP listener against the built handle.

    Subscription handles are intentionally discarded: the bus
    owns them for the lifetime of the process. The SSE registry
    itself stays opaque in the public surface; only {!serve} (in
    this module) reaches into it to plug it into
    {!Server.Http.run}. *)

module Stream = Server.Stream
module Bar_updated_ie = Server_external_integration_events.Bar_updated_integration_event
module Bar_updated_ie_handler =
  Server_external_integration_events.Bar_updated_integration_event_handler
module Order_accepted_ie =
  Server_external_integration_events.Order_accepted_integration_event
module Order_rejected_ie =
  Server_external_integration_events.Order_rejected_integration_event
module Order_unreachable_ie =
  Server_external_integration_events.Order_unreachable_integration_event
module Bar_subscription = Server_application_ports.Bar_subscription

type t = { registry : Stream.t }

let build ~bus ~(bar_subscription : Bar_subscription.t) : t =
  let registry =
    Stream.create ~on_first_subscriber:bar_subscription.watch
      ~on_last_unsubscriber:bar_subscription.unwatch ()
  in
  let consumer (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://broker.bar-updated" ~group:"sse-stream"
         ~t_of_yojson:Bar_updated_ie.t_of_yojson)
      (Bar_updated_ie_handler.handle ~push:(Stream.push_bar registry))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://account.amount-reserved" ~group:"sse-publisher"
         ~t_of_yojson:
           Account_integration_events.Amount_reserved_integration_event.t_of_yojson)
      (Server.Publish_order_events.handle_amount_reserved ~registry)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://account.reservation-released" ~group:"sse-publisher"
         ~t_of_yojson:
           Account_integration_events.Reservation_released_integration_event.t_of_yojson)
      (Server.Publish_order_events.handle_reservation_released ~registry)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://account.reservation-rejected" ~group:"sse-publisher"
         ~t_of_yojson:
           Account_integration_events.Reservation_rejected_integration_event.t_of_yojson)
      (Server.Publish_order_events.handle_reservation_rejected ~registry)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://broker.order-accepted" ~group:"sse-publisher"
         ~t_of_yojson:Order_accepted_ie.t_of_yojson)
      (Server.Publish_order_events.handle_order_accepted ~registry)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://broker.order-rejected" ~group:"sse-publisher"
         ~t_of_yojson:Order_rejected_ie.t_of_yojson)
      (Server.Publish_order_events.handle_order_rejected ~registry)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consumer ~uri:"in-memory://broker.order-unreachable" ~group:"sse-publisher"
         ~t_of_yojson:Order_unreachable_ie.t_of_yojson)
      (Server.Publish_order_events.handle_order_unreachable ~registry)
  in
  { registry }

let serve t ?bc_handlers ~sw ~env ~port ~broker () =
  Server.Http.run ?bc_handlers ~registry:t.registry ~sw ~env ~port ~broker ()

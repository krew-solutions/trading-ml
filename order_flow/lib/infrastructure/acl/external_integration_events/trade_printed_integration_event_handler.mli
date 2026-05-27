(** ACL handler: translates the broker BC's public-tape
    {!Trade_printed_integration_event.t} into an {!Ingest_print_command.t}
    and invokes the order_flow workflow in-process (bypassing the bus,
    per the ACL convention).

    The aggressor string is passed through untouched — the
    BUY/SELL/UNSPECIFIED normalisation, and the side-mapping caveat of
    ADR 0032, live at the broker's WS boundary, not here. The forming
    bar per instrument is reached through the [get_bar] / [put_bar]
    ports supplied by the composition root. *)

val handle :
  boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
  get_bar:(Core.Instrument.t -> Order_flow.Footprint.t option) ->
  put_bar:(Core.Instrument.t -> Order_flow.Footprint.t -> unit) ->
  publish_footprint_completed:
    (Order_flow_integration_events.Footprint_completed_integration_event.t -> unit) ->
  Trade_printed_integration_event.t ->
  unit

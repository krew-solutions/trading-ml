(** ACL handler: translates the broker BC's public-tape
    {!Public_trade_printed_integration_event.t} into an {!Ingest_print_command.t}
    and invokes the order_flow workflow in-process (bypassing the bus,
    per the ACL convention).

    The aggressor string is passed through untouched — the
    BUY/SELL/UNSPECIFIED normalisation, and the side-mapping caveat of
    ADR 0032, live at the broker's WS boundary, not here.

    One external print fans into every boundary watched for its
    instrument: [boundaries_for] yields that list (the operator's default
    boundary is always included), and the print is ingested once per
    boundary against its own [(instrument, boundary)]-keyed forming bar,
    reached through the [get_bar] / [put_bar] ports supplied by the
    composition root. This is what makes footprints demand-driven — a UI
    watching an M1 boundary gets M1 footprints alongside the configured
    default — while reusing the single-boundary workflow unchanged. *)

val handle :
  boundaries_for:(string -> Order_flow.Footprint.Values.Bar_boundary.t list) ->
  get_bar:
    (Core.Instrument.t ->
    Order_flow.Footprint.Values.Bar_boundary.t ->
    Order_flow.Footprint.t option) ->
  put_bar:
    (Core.Instrument.t ->
    Order_flow.Footprint.Values.Bar_boundary.t ->
    Order_flow.Footprint.t ->
    unit) ->
  publish_footprint_completed:
    (Order_flow_integration_events.Footprint_completed_integration_event.t -> unit) ->
  Public_trade_printed_integration_event.t ->
  unit

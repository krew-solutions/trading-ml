module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

(* Command workflow (ROP): ingest one print, then route the resulting
   domain event. Only [Rolled] carries an outbound integration event —
   a bar sealed when the print crossed into a new bucket. [Opened] and
   [Absorbed] are internal lifecycle (no IE); [Rejected_late] is a benign
   no-op (logging/metrics belong here when the observability port lands).

   The forming bar per instrument is held by the caller through the
   [get_bar] / [put_bar] ports — transitional in-memory persistence,
   like Account's portfolio ref. *)
let execute
    ~(boundary : Order_flow.Footprint.Values.Bar_boundary.t)
    ~(get_bar : Core.Instrument.t -> Order_flow.Footprint.t option)
    ~(put_bar : Core.Instrument.t -> Order_flow.Footprint.t -> unit)
    ~(publish_footprint_completed : Footprint_completed_ie.t -> unit)
    (cmd : Ingest_print_command.t) :
    (unit, Ingest_print_command_handler.handle_error) Rop.t =
  match Ingest_print_command_handler.handle ~boundary ~get_bar ~put_bar cmd with
  | Ok outcome ->
      (match outcome with
      | Ingest_print_command_handler.Rolled (completed, _opened) ->
          Order_flow_domain_event_handlers
          .Publish_integration_event_on_footprint_completed
          .handle ~publish_footprint_completed completed
      | Ingest_print_command_handler.Opened _
      | Ingest_print_command_handler.Absorbed
      | Ingest_print_command_handler.Rejected_late -> ());
      Rop.succeed ()
  | Error errs -> Error errs

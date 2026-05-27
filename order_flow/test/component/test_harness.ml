(** In-process test harness for the order_flow BC.

    Drives the application-layer workflow ({!Ingest_print_command_workflow})
    — not the handler — so the component boundary includes the outbound
    integration-event projection. The forming bar per instrument lives
    in an in-memory store (transitional persistence); the Hexagonal
    outbound port [publish_footprint_completed] is substituted with an
    in-memory recorder whose list the Then-steps inspect. *)

module Ingest_wf = Order_flow_commands.Ingest_print_command_workflow
module Ingest_h = Order_flow_commands.Ingest_print_command_handler
module Footprint = Order_flow.Footprint
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary

module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

type ctx = {
  store : (string, Footprint.t) Hashtbl.t;  (** keyed by Instrument.to_qualified *)
  boundary : Bar_boundary.t;
  footprint_completed_pub : Footprint_completed_ie.t list ref;
  last_result : (unit, Ingest_h.handle_error) Rop.t option;
}

let fresh_ctx () =
  {
    store = Hashtbl.create 8;
    boundary = Bar_boundary.Time Core.Timeframe.M5;
    footprint_completed_pub = ref [];
    last_result = None;
  }

let ingest ctx ~symbol ~price ~size ~ts ~aggressor =
  let cmd : Order_flow_commands.Ingest_print_command.t =
    { symbol; price; size; ts; aggressor }
  in
  let get_bar inst = Hashtbl.find_opt ctx.store (Core.Instrument.to_qualified inst) in
  let put_bar inst bar =
    Hashtbl.replace ctx.store (Core.Instrument.to_qualified inst) bar
  in
  let publish_footprint_completed e =
    ctx.footprint_completed_pub := e :: !(ctx.footprint_completed_pub)
  in
  let result =
    Ingest_wf.execute ~boundary:ctx.boundary ~get_bar ~put_bar
      ~publish_footprint_completed cmd
  in
  { ctx with last_result = Some result }

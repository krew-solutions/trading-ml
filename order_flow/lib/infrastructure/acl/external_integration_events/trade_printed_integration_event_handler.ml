module Cmd = Order_flow_commands.Ingest_print_command
module Workflow = Order_flow_commands.Ingest_print_command_workflow

let handle
    ~(boundary : Order_flow.Footprint.Values.Bar_boundary.t)
    ~(get_bar : Core.Instrument.t -> Order_flow.Footprint.t option)
    ~(put_bar : Core.Instrument.t -> Order_flow.Footprint.t -> unit)
    ~(publish_footprint_completed :
       Order_flow_integration_events.Footprint_completed_integration_event.t -> unit)
    (ie : Trade_printed_integration_event.t) : unit =
  let cmd : Cmd.t =
    {
      symbol = ie.symbol;
      price = ie.price;
      size = ie.size;
      ts = ie.ts;
      aggressor = ie.aggressor;
    }
  in
  match Workflow.execute ~boundary ~get_bar ~put_bar ~publish_footprint_completed cmd with
  | Ok () -> ()
  | Error _ -> ()
(* Idempotent ACL: a malformed external print (validation failure) is
   absorbed — the producer-contract violation has no own-model action
   and is surfaced on the producer side, not here. *)

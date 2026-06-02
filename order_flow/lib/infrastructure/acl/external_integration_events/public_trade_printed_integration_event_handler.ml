module Cmd = Order_flow_commands.Ingest_print_command
module Workflow = Order_flow_commands.Ingest_print_command_workflow
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary

let handle
    ~(boundaries_for : string -> Bar_boundary.t list)
    ~(get_bar : Core.Instrument.t -> Bar_boundary.t -> Order_flow.Footprint.t option)
    ~(put_bar : Core.Instrument.t -> Bar_boundary.t -> Order_flow.Footprint.t -> unit)
    ~(publish_footprint_completed :
       Order_flow_integration_events.Footprint_completed_integration_event.t -> unit)
    (ie : Public_trade_printed_integration_event.t) : unit =
  let cmd : Cmd.t =
    {
      symbol = ie.symbol;
      price = ie.price;
      size = ie.size;
      ts = ie.ts;
      aggressor = ie.aggressor;
    }
  in
  (* Fan the one external print into every boundary currently watched for
     this instrument (the operator's default boundary is always in the
     list — see the factory's [boundaries_for]). Each boundary is an
     independent forming-bar aggregate reached through its own keyed
     [get_bar]/[put_bar] slice, so the single-boundary workflow is reused
     unchanged, once per boundary. The clusters' commutative algebra makes
     the per-boundary work independent; ordering across boundaries is
     irrelevant. *)
  List.iter
    (fun boundary ->
      let get_bar_b inst = get_bar inst boundary in
      let put_bar_b inst bar = put_bar inst boundary bar in
      match
        Workflow.execute ~boundary ~get_bar:get_bar_b ~put_bar:put_bar_b
          ~publish_footprint_completed cmd
      with
      | Ok () -> ()
      | Error _ -> ())
    (boundaries_for ie.symbol)
(* Idempotent ACL: a malformed external print (validation failure) is
   absorbed — the producer-contract violation has no own-model action and
   is surfaced on the producer side, not here. *)

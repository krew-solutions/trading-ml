module Position_changed = Position_changed_integration_event

module Make (Bus : Bus.Event_bus.S) = struct
  let to_command (ev : Position_changed.t) :
      Portfolio_management_commands.Project_position_changed_command.t =
    {
      book_id = ev.book_id;
      instrument =
        (* Reconstruct the qualified textual form from the view model;
           the command handler re-parses it via Core.Instrument.of_qualified.
           Carrying a view model into a wire-format command would leak the
           queries layer's representation into commands, which is exactly
           what the ACL is here to prevent — and the qualified form is the
           canonical wire identity. *)
        (let i = ev.instrument in
         match i.board with
         | Some b -> Printf.sprintf "%s@%s/%s" i.ticker i.venue b
         | None -> Printf.sprintf "%s@%s" i.ticker i.venue);
      delta_qty = ev.delta_qty;
      new_qty = ev.new_qty;
      avg_price = ev.avg_price;
      occurred_at = ev.occurred_at;
    }

  let attach
      ~(events : Position_changed.t Bus.t)
      ~(dispatch_project_position_changed :
         Portfolio_management_commands.Project_position_changed_command.t -> unit) :
      Bus.subscription =
    Bus.subscribe events (fun ev -> dispatch_project_position_changed (to_command ev))
end

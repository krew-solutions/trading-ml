module Position_changed = Position_changed_integration_event

let to_command (ev : Position_changed.t) :
    Portfolio_management_commands.Change_position_command.t =
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

let handle
    ~(dispatch_change_position :
       Portfolio_management_commands.Change_position_command.t -> unit)
    (ev : Position_changed.t) : unit =
  dispatch_change_position (to_command ev)

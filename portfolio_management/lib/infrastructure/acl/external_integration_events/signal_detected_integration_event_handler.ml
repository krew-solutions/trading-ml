module Signal_detected = Signal_detected_integration_event
module Instrument_vm = Portfolio_management_external_view_models.Instrument_view_model

let qualify (i : Instrument_vm.t) : string =
  let base = Printf.sprintf "%s@%s" i.ticker i.venue in
  match i.board with
  | Some b -> base ^ "/" ^ b
  | None -> base

let handle
    ~(dispatch_define_alpha_view :
       Portfolio_management_commands.Define_alpha_view_command.t -> unit)
    (ev : Signal_detected.t) : unit =
  let cmd : Portfolio_management_commands.Define_alpha_view_command.t =
    {
      alpha_source_id = ev.strategy_id;
      instrument = qualify ev.instrument;
      direction = ev.direction;
      strength = ev.strength;
      price = ev.price;
      occurred_at = ev.occurred_at;
    }
  in
  dispatch_define_alpha_view cmd

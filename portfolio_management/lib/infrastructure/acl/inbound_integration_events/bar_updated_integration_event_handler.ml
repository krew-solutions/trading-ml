module Apply_bar_command = Portfolio_management_commands.Apply_bar_command

let qualify (vm : Portfolio_management_inbound_queries.Instrument_view_model.t) : string =
  match vm.board with
  | Some b -> Printf.sprintf "%s@%s/%s" vm.ticker vm.venue b
  | None -> Printf.sprintf "%s@%s" vm.ticker vm.venue

let handle
    ~(dispatch_apply_bar : Apply_bar_command.t -> unit)
    (ev : Bar_updated_integration_event.t) : unit =
  let bar : Apply_bar_command.bar_dto =
    {
      ts = ev.bar.ts;
      open_ = ev.bar.open_;
      high = ev.bar.high;
      low = ev.bar.low;
      close = ev.bar.close;
      volume = ev.bar.volume;
    }
  in
  dispatch_apply_bar { instrument = qualify ev.instrument; timeframe = ev.timeframe; bar }

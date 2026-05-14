module Apply_bar_command = Paper_broker_commands.Apply_bar_command

let qualify (vm : Paper_broker_inbound_queries.Instrument_view_model.t) : string =
  match vm.board with
  | Some b -> Printf.sprintf "%s@%s/%s" vm.ticker vm.venue b
  | None -> Printf.sprintf "%s@%s" vm.ticker vm.venue

let handle
    ~(dispatch_apply_bar : Apply_bar_command.t -> unit)
    (ev : Bar_updated_integration_event.t) : unit =
  let candle : Apply_bar_command.candle_dto =
    {
      ts = ev.candle.ts;
      open_ = ev.candle.open_;
      high = ev.candle.high;
      low = ev.candle.low;
      close = ev.candle.close;
      volume = ev.candle.volume;
    }
  in
  dispatch_apply_bar
    { instrument = qualify ev.instrument; timeframe = ev.timeframe; candle }

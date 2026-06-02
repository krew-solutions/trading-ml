let execute
    ~(watch :
       instrument:Core.Instrument.t ->
       boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
       unit)
    (cmd : Watch_footprints_command.t) :
    (unit, Watch_footprints_command_handler.handle_error) Rop.t =
  match Watch_footprints_command_handler.handle ~watch cmd with
  | Ok () -> Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Watch_footprints_command_handler.Validation v ->
              Log.warn "[order_flow watch_footprints] %s"
                (Watch_footprints_command_handler.validation_error_to_string v))
        errs;
      Error errs

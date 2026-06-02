let execute
    ~(unwatch :
       instrument:Core.Instrument.t ->
       boundary:Order_flow.Footprint.Values.Bar_boundary.t ->
       unit)
    (cmd : Unwatch_footprints_command.t) :
    (unit, Unwatch_footprints_command_handler.handle_error) Rop.t =
  match Unwatch_footprints_command_handler.handle ~unwatch cmd with
  | Ok () -> Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Unwatch_footprints_command_handler.Validation v ->
              Log.warn "[order_flow unwatch_footprints] %s"
                (Unwatch_footprints_command_handler.validation_error_to_string v))
        errs;
      Error errs

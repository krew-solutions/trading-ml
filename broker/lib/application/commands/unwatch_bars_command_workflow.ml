let execute ~(broker : Broker.client) (cmd : Unwatch_bars_command.t) :
    (unit, Unwatch_bars_command_handler.handle_error) Rop.t =
  match Unwatch_bars_command_handler.handle ~broker cmd with
  | Ok () -> Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Unwatch_bars_command_handler.Validation v ->
              Log.warn "[broker unwatch_bars] %s"
                (Unwatch_bars_command_handler.validation_error_to_string v))
        errs;
      Error errs

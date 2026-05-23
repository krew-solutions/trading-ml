let execute ~(broker : Broker.client) (cmd : Watch_bars_command.t) :
    (unit, Watch_bars_command_handler.handle_error) Rop.t =
  match Watch_bars_command_handler.handle ~broker cmd with
  | Ok () -> Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Watch_bars_command_handler.Validation v ->
              Log.warn "[broker watch_bars] %s"
                (Watch_bars_command_handler.validation_error_to_string v))
        errs;
      Error errs

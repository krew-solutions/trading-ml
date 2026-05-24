let execute ~persist_pair_kalman_mr_state (cmd : Define_pair_kalman_mr_command.t) :
    (unit, Define_pair_kalman_mr_command_handler.handle_error) Rop.t =
  Define_pair_kalman_mr_command_handler.handle ~persist_pair_kalman_mr_state cmd

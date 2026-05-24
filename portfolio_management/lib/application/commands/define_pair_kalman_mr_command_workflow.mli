(** ROP pipeline for {!Define_pair_kalman_mr_command.t}. Thin wrapper
    around the handler — no downstream side effects beyond the
    persist closure. *)

val execute :
  persist_pair_kalman_mr_state:
    (book_id:Portfolio_management.Common.Book_id.t ->
    pair:Portfolio_management.Common.Pair.t ->
    state:Portfolio_management.Pair_kalman_mean_reversion.state ->
    unit) ->
  Define_pair_kalman_mr_command.t ->
  (unit, Define_pair_kalman_mr_command_handler.handle_error) Rop.t

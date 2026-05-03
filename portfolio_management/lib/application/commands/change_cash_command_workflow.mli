(** ROP pipeline for {!Change_cash_command.t}. *)

val execute :
  actual_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Change_cash_command.t ->
  (unit, Change_cash_command_handler.handle_error) Rop.t

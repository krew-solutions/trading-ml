(** ROP pipeline for {!Project_cash_changed_command.t}. *)

val execute :
  actual_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Project_cash_changed_command.t ->
  (unit, Project_cash_changed_command_handler.handle_error) Rop.t

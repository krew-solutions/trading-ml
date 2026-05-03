(** ROP pipeline for {!Change_position_command.t}. Trivial:
    runs the handler and discards the domain event — there is no
    outbound integration event for this projection (the change is
    purely internal to PM's actual_portfolio model). *)

val execute :
  actual_portfolio_for:
    (Portfolio_management.Shared.Book_id.t ->
    Portfolio_management.Actual_portfolio.t ref option) ->
  Change_position_command.t ->
  (unit, Change_position_command_handler.handle_error) Rop.t

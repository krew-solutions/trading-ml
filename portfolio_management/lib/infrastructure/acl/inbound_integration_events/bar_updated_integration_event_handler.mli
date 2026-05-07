(** Inbound translation handler for {!Bar_updated_integration_event.t}.

    Pure ACL: rebuilds the qualified instrument string from the view-
    model fields, copies bar OHLCV strings as-is, and dispatches an
    {!Portfolio_management_commands.Apply_bar_command.t}. No domain
    logic, no parsing of decimals or timestamps — that work belongs
    to the command handler.

    Idempotency lives one layer down: the workflow's
    {!Portfolio_management.Target_portfolio.apply_proposal} keys by
    [(book_id, instrument)] within the aggregate. Repeat publications
    of the same wire bar are part of the upstream contract; this
    handler doesn't deduplicate. *)

val handle :
  dispatch_apply_bar:(Portfolio_management_commands.Apply_bar_command.t -> unit) ->
  Bar_updated_integration_event.t ->
  unit

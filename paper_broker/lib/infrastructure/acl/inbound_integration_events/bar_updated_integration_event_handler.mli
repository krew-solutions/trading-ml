(** Inbound translation handler for {!Bar_updated_integration_event.t}.

    Pure ACL: rebuilds the qualified instrument string from the
    view-model fields, copies bar OHLCV strings as-is, and
    dispatches a {!Paper_broker_commands.Apply_bar_command.t}. No
    domain logic, no parsing of decimals or timestamps — that work
    belongs to the command handler.

    Idempotency is the upstream contract's responsibility; this
    handler does not deduplicate. *)

val handle :
  dispatch_apply_bar:(Paper_broker_commands.Apply_bar_command.t -> unit) ->
  Bar_updated_integration_event.t ->
  unit

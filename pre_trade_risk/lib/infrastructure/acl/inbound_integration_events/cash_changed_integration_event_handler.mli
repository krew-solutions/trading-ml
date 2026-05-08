(** Handler for the inbound {!Cash_changed_integration_event.t}. *)

module Cash_changed = Cash_changed_integration_event

val handle :
  dispatch_record_cash:(Pre_trade_risk_commands.Record_cash_command.t -> unit) ->
  Cash_changed.t ->
  unit

(** ROP pipeline for {!Configure_risk_command.t}. Today only a
    thin wrapper around {!Configure_risk_command_handler.handle}
    — no downstream side effects beyond the in-memory persist
    closure. *)

val execute :
  persist_risk_config:
    (Portfolio_management.Common.Book_id.t -> Portfolio_management.Risk_config.t -> unit) ->
  Configure_risk_command.t ->
  (unit, Configure_risk_command_handler.handle_error) Rop.t

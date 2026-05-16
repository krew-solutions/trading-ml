(** Handler for the inbound {!Signal_detected_integration_event.t}.

    Translates each emitted strategy signal into a
    {!Portfolio_management_commands.Define_alpha_view_command.t} and
    dispatches via the supplied port. The mapping
    [strategy_id → alpha_source_id] is the identity by default —
    PM treats the strategy_id as the alpha-source key. A future
    multi-tenant deployment may insert a configuration step here. *)

module Signal_detected = Signal_detected_integration_event

val handle :
  dispatch_define_alpha_view:
    (Portfolio_management_commands.Define_alpha_view_command.t -> unit) ->
  Signal_detected.t ->
  unit

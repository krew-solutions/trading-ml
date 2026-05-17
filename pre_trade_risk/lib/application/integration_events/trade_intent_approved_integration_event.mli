(** Integration event: pre_trade_risk approved a trade leg.

    Published by {!Assess_trade_intent_command_workflow} after
    {!Pre_trade_risk.Assessment.assess} returns [Approve qty]. The
    [correlation_id] echoes the originating
    {!Assess_trade_intent_command.t} so the {!Order_process_manager} Process
    Manager in [execution_management] can route the approval back to
    the originating saga instance.

    [quantity] is the gate's accepted quantity — typically equal to
    the proposed quantity (the gate vetoes, it does not down-scale),
    but the field is carried explicitly so a future smart-gate that
    reduces size can extend the contract without breaking the wire
    shape.

    DTO-shaped: primitives only. The wire shape is generated from
    [shared/contracts/pre_trade_risk/integration_events/trade_intent_approved_integration_event.atd]
    via atdgen. *)

include module type of Trade_intent_approved_integration_event_t

include module type of Trade_intent_approved_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

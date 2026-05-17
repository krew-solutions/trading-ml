(** Inbound command to the pre_trade_risk BC: "assess this proposed
    trade leg against the current Risk_view and the configured
    Risk_limits."

    Wire-format DTO — primitives + view-model DTOs, no
    {!Core.Instrument.t} / {!Core.Side.t} / {!Decimal.t}.

    Dispatched by the inbound ACL handler that subscribes to
    {!Portfolio_management_integration_events.Trade_intents_planned_integration_event};
    one command per leg, each carrying its own [correlation_id] minted
    by PM.

    Outcome flows back through {!Trade_intent_approved_integration_event}
    or {!Trade_intent_rejected_integration_event} on the BC's outbound
    bus; the {!Order_process_manager} Process Manager in [execution_management]
    keys both by [correlation_id].

    The wire shape is generated from
    [shared/contracts/pre_trade_risk/commands/assess_trade_intent_command.atd]
    via atdgen. *)

include module type of Assess_trade_intent_command_t

include module type of Assess_trade_intent_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

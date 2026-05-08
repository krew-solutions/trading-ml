(** Integration event: pre_trade_risk approved a trade leg.

    Published by {!Assess_trade_intent_command_workflow} after
    {!Pre_trade_risk.Assessment.assess} returns [Approve qty]. The
    [correlation_id] echoes the originating
    {!Assess_trade_intent_command.t} so the {!Place_order_pm} Process
    Manager in [execution_management] can route the approval back to
    the originating saga instance.

    [quantity] is the gate's accepted quantity — typically equal to
    the proposed quantity (the gate vetoes, it does not down-scale),
    but the field is carried explicitly so a future smart-gate that
    reduces size can extend the contract without breaking the wire
    shape.

    DTO-shaped: primitives only. *)

type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
}
[@@deriving yojson]

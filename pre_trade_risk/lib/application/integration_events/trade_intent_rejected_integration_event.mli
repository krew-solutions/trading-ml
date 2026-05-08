(** Integration event: pre_trade_risk rejected a trade leg.

    Published by {!Assess_trade_intent_command_workflow} after
    {!Pre_trade_risk.Assessment.assess} returns [Reject reason].
    [correlation_id] echoes the originating command so the saga
    Process Manager terminates the corresponding instance through its
    compensation path (no Reserve_command is dispatched on a
    rejection). *)

type t = {
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  reason : string;
}
[@@deriving yojson]

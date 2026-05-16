(** Wire-format command: cancel a working order at the venue,
    addressed by its cross-BC [placement_id] (the saga key minted
    by Account at reservation time and echoed through Submit).
    Broker resolves [placement_id] to its venue-native handle
    inside the selected ACL adapter (its private
    {!Placement_handle_store}) and calls the venue.

    [correlation_id] is the saga-instance identifier of the
    cancellation request itself — distinct from the originating
    Submit's [correlation_id]; the outbound
    {!Order_cancelled_integration_event} carries this cancel
    correlation, not the Submit's.

    The wire shape is generated from
    [shared/contracts/broker/commands/cancel_pending_order_command.atd]
    via atdgen and is shared byte-identically with paper_broker:
    in backtest mode paper_broker substitutes for broker and the
    saga's cancel command must round-trip identically through
    either BC. *)

include module type of Cancel_pending_order_command_t
include module type of Cancel_pending_order_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

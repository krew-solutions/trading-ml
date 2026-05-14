(** Wire-format command: cancel a working order by its
    paper_broker-assigned [id]. The [correlation_id] is the
    saga-instance identifier of the cancellation request itself —
    distinct from the originating submit's [correlation_id], which
    {!Cancel_pending_order_command_workflow.execute} retrieves
    from the persisted {!Pending_order.t} so the outbound
    integration event echoes the submit-time saga. *)

type t = { correlation_id : string; id : string } [@@deriving yojson]

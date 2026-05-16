(** Wire-format command: cancel a working order, addressed by its
    cross-BC [placement_id] (the saga key minted by Account when
    reserving and echoed through Submit). The receiving BC's
    handler maps placement_id to its local identifier internally —
    paper_broker looks up its surrogate [Order.id] via the store's
    [update_by_placement_id]; broker (once migrated off HTTP
    DELETE) maps to its [client_order_id] and calls the venue.

    The [correlation_id] is the saga-instance identifier of the
    cancellation request itself — distinct from the originating
    submit's [correlation_id], which the receiving BC retrieves
    from its persisted command log so the outbound
    [Order_cancelled] integration event echoes the submit-time
    saga.

    The wire shape is generated from
    [shared/contracts/broker/commands/cancel_pending_order_command.atd]
    via atdgen; broker BC owns the contract today even though only
    paper_broker generates a handler. *)

include module type of Cancel_pending_order_command_t

include module type of Cancel_pending_order_command_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

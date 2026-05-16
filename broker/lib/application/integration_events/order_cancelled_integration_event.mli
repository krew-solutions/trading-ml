(** Integration event: broker observed the venue acknowledge a
    cancel. Published by {!Cancel_pending_order_command_workflow}
    on [in-memory://broker.order-cancelled] after a successful
    placement-keyed cancel call.

    [correlation_id] is the saga-instance identifier of the
    cancel command — distinct from the originating Submit's
    correlation_id (which the receiving BC retrieves from its
    Order_command_log if it needs the submit-time saga).

    [placement_id] echoes the saga key supplied in
    {!Cancel_pending_order_command.t}; consumers (Account
    compensation, audit, SSE) match by it.

    [cancelled_ts] is sourced from broker's injected Clock
    (UnixClock live / VirtualClock backtest), not the venue's
    own server-side timestamp — venues expose those under
    wildly inconsistent shapes and broker deliberately does not
    surface them. *)

include module type of Order_cancelled_integration_event_t
include module type of Order_cancelled_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

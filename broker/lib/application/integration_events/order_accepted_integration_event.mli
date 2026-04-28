(** Integration event: the broker accepted a submission.
    Published by {!Submit_order_command_handler} after a successful
    {!Broker.place_order} call whose returned [Order.status] is
    NOT [Rejected].

    [reservation_id] echoes the saga key supplied in
    {!Submit_order_command.t}; consumers (SSE, audit, Account
    correlation) match by it.

    [broker_order] is the Order DTO as observed at submission time —
    [status] is typically [New] / [Pending_new], but may already
    reflect a partial or full fill on aggressive orders. The
    [client_order_id] field inside is Broker's wire identity (used
    by the UI for [GET / DELETE /api/orders/<cid>]); Account does
    not consume it. *)

type t = { reservation_id : int; broker_order : Queries.Order_view_model.t }
[@@deriving yojson]

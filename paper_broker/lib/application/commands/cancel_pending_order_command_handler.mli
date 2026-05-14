(** Command handler for {!Cancel_pending_order_command.t}.

    Atomically transitions the addressed {!Pending_order.t} via
    {!Paper_broker.Order.cancel} under the {!Order_store.S}'s
    serialisation primitive, yielding either the post-cancel
    pending order plus its domain event or a discriminated failure
    explaining why the cancellation was rejected. *)

(** {1 Failure surface} *)

type cancel_error =
  | Order_not_found of string  (** No {!Pending_order.t} is tracked under this id. *)
  | Order_already_terminal of Paper_broker.Order.Values.Order_status.t
      (** The addressed order is in a terminal status
          (Filled / Cancelled / Rejected / Expired) and cannot
          transition any further. *)

val cancel_error_to_string : cancel_error -> string

(** {1 Outcome} *)

type handle_error = Cancel of cancel_error

type cancel_outcome = {
  pending : Pending_order.t;
  event : Paper_broker.Order.Events.Order_cancelled.t;
}

module type Store = Order_store.S

val handle :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  now_ts:(unit -> int64) ->
  Cancel_pending_order_command.t ->
  (cancel_outcome, handle_error) Rop.t

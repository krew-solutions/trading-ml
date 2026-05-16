(** Command handler for {!Cancel_pending_order_command.t}.

    Atomically transitions the addressed {!Paper_broker.Order.t} via
    {!Paper_broker.Order.cancel} under the
    {!Paper_broker_store.Order_store.S}'s serialisation primitive,
    yielding either the post-cancel aggregate plus its domain event
    or a discriminated failure. *)

(** {1 Failure surface} *)

type cancel_error =
  | Order_not_found of int
      (** No working {!Paper_broker.Order.t} is tracked under this
          [placement_id]. *)
  | Order_already_terminal of Paper_broker.Order.Values.Order_status.t
      (** The addressed order is in a terminal status
          (Filled / Cancelled / Rejected / Expired) and cannot
          transition any further. *)

val cancel_error_to_string : cancel_error -> string

(** {1 Outcome} *)

type handle_error = Cancel of cancel_error

type cancel_outcome = {
  order : Paper_broker.Order.t;
  event : Paper_broker.Order.Events.Order_cancelled.t;
}

module type Store = Paper_broker_store.Order_store.S

val handle :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  now_ts:(unit -> int64) ->
  Cancel_pending_order_command.t ->
  (cancel_outcome, handle_error) Rop.t

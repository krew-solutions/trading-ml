(** Command handler for {!Apply_bar_command.t}.

    Wire-format primitives are parsed back into a domain
    {!Core.Candle.t}, then every active {!Pending_order.t} on the
    bar's instrument is tested against the matching rules.
    Pending orders that match are atomically updated in the
    {!Order_store.S} via {!Order_store.S.update} and the resulting
    {!Paper_broker.Order.Events.Fill_observed.t} domain events are
    returned for the enclosing workflow to translate into outbound
    integration events.

    No partial-fill participation cap is applied in this cut — a
    matched order fills its full remaining quantity at the
    canonical (then slipped) price. A future participation_rate
    parameter would slice [fill_quantity] proportionally to
    [candle.volume]. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_ts of string
  | Invalid_candle of string

val validation_error_to_string : validation_error -> string

(** {1 Outcome} *)

type handle_error = Validation of validation_error

type fill_outcome = {
  pending : Pending_order.t;
  event : Paper_broker.Order.Events.Fill_observed.t;
}
(** Per-order fill: the post-fill {!Pending_order.t} (whose
    underlying {!Paper_broker.Order.t} reflects the new
    [filled]/[status]) plus the corresponding domain event. *)

module type Store = Order_store.S

val handle :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.t ->
  fee_rate:Paper_broker.Fee.Values.Fee_rate.t ->
  next_exec_id:(unit -> string) ->
  Apply_bar_command.t ->
  (fill_outcome list, handle_error) Rop.t
(** Parse the bar, sweep active orders on the matching instrument,
    atomically apply fills and yield the list of resulting fills.
    Wire-format validation failures short-circuit before any store
    interaction. *)

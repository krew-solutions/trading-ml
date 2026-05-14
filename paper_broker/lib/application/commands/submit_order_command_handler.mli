(** Command handler for {!Submit_order_command.t}.

    Owns the entire submission step: parse the wire-format command,
    validate the primitives back into domain VOs (side, instrument,
    decimal qty, kind variant, tif), allocate a fresh order id via
    the injected port, build the {!Paper_broker.Order.t} aggregate
    via {!Paper_broker.Order.make}, wrap it in a {!Pending_order.t}
    with the round-trip [reservation_id], and persist via the
    {!Order_store.S} port.

    Returns the persisted {!Pending_order.t} plus the resulting
    {!Paper_broker.Order.Events.Order_accepted.t} domain event. The
    enclosing {!Submit_order_command_workflow} is responsible for
    handing the DE to the domain-event handler that publishes the
    corresponding {!Paper_broker_integration_events.Order_accepted_integration_event.t}. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_kind of string
  | Invalid_kind_price_format of { field : string; value : string }
  | Non_positive_kind_price of { field : string; value : string }
  | Missing_kind_price of { kind : string; field : string }
  | Invalid_tif of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_submit_order_command = {
  correlation_id : string;
  reservation_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  kind : Paper_broker.Order.Values.Order_kind.t;
  tif : Paper_broker.Order.Values.Time_in_force.t;
}
(** Post-parse intermediate form. Wlaschin's [ValidatedX]: syntax
    has been parsed into domain types but the order has not yet
    been built nor persisted. *)

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
      (** The only failure surface for [Submit_order_command_handler] is
    wire-validation. Once parsed, {!Paper_broker.Order.make} is
    total (its [Invalid_argument] cases are forbidden by the
    validator), and {!Order_store.S.save} collisions are programmer
    errors (the injected [next_order_id] must produce a fresh id). *)

module type Store = Order_store.S

val handle :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  next_order_id:(unit -> string) ->
  now_ts:(unit -> int64) ->
  placed_after_ts:(Core.Instrument.t -> int64) ->
  Submit_order_command.t ->
  (Pending_order.t * Paper_broker.Order.Events.Order_accepted.t, handle_error) Rop.t
(** Parse the wire-format command, build and persist the pending
    order, and yield the resulting domain event. Does not publish
    any integration event — that is the
    {!Submit_order_command_workflow.execute} pipeline's job.

    Ports:
    - [next_order_id] — server-side id generator. Must be unique
      against the store; a collision raises [Invalid_argument].
    - [now_ts] — current wall-clock ms-precision timestamp.
    - [placed_after_ts] — instrument-specific "floor" timestamp;
      the order may only fill at bars with [ts > placed_after_ts]
      (no-lookahead rule). Typically the last seen bar timestamp
      for that instrument. *)

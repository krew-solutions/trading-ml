(** Workflow: pipeline that composes PlaceOrder from the
    command to the terminal set of domain events.

    Top-level entry point for the HTTP adapter. Composes:
    - {!Commands.Place_order_command.to_unvalidated}  (parse + validate)
    - {!Commands.Place_order_command.reserve}          (step 1: reserve)
    - {!Domain_event_handlers.Forward_order_to_broker.handle}
                                                       (step 2: send to broker)
    - {!Domain_event_handlers.Release_reservation_on_broker_rejection.handle}
                                                       (branch: broker said no)

    Returns the new portfolio state plus a list of every domain
    event produced along the way. On full-stop failures
    (validation, invariant violation on reserve) no events are
    emitted and a typed error is returned — the workflow never
    started or stopped before any state changed. *)

type event =
  | Amount_reserved of Account.Portfolio.amount_reserved
  | Order_forwarded of Domain_event_handlers.Forward_order_to_broker.order_forwarded
  | Forward_rejected of Domain_event_handlers.Forward_order_to_broker.forward_rejection
  | Reservation_released of Account.Portfolio.reservation_released

type error =
  | Validation_errors of Commands.Place_order_command.validation_error list
  | Reservation_rejected of Account.Portfolio.reservation_error

val run :
  portfolio:Account.Portfolio.t ->
  market_price:Core.Decimal.t ->
  slippage_buffer:float ->
  fee_rate:float ->
  next_reservation_id:(unit -> int) ->
  place_order:Domain_event_handlers.Forward_order_to_broker.place_order_port ->
  Commands.Place_order_command.t ->
  (Account.Portfolio.t * event list, error) result

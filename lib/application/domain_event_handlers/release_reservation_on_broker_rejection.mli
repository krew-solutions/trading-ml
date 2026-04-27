(** Domain event handler: reacts to
    {!Forward_order_to_broker.forward_rejection} by releasing
    the earmark on the local portfolio.

    Source-agnostic: triggers whenever the broker refused our
    order (either rejected the submission or was unreachable).
    Both failure-paths converge on the same treatment — drop the
    reservation so the cash/qty becomes available again. *)

val handle :
  portfolio:Account.Portfolio.t ->
  Forward_order_to_broker.forward_rejection ->
  ( Account.Portfolio.t * Account.Portfolio.reservation_released,
    Account.Portfolio.release_error )
  Rop.t

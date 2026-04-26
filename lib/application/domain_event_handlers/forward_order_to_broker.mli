(** Domain event handler: reacts to {!Engine.Portfolio.amount_reserved}
    by forwarding the reservation to the broker as a new order.

    Triggered by any source of the event: the manual
    [Place_order_command], or a future [Live_engine] path where a
    strategy signals entry. The handler itself is source-agnostic.

    Needs extra command-context (kind, tif, client_order_id) that
    the domain event doesn't carry — Portfolio's reservation
    knows only side/instrument/quantity/price. The caller threads
    that context in. *)

open Core

type place_order_port =
  instrument:Instrument.t ->
  side:Side.t ->
  quantity:Decimal.t ->
  kind:Order.kind ->
  tif:Order.time_in_force ->
  client_order_id:string ->
  Order.t

type order_forwarded = {
  client_order_id : string;
  reservation_id : int;
  broker_order : Order.t;
}
(** Success event: the broker accepted the submission.
    [broker_order.status] is usually [New] but may already
    reflect a partial or full fill. *)

type forward_rejection =
  | Order_rejected_by_broker of {
      client_order_id : string;
      reservation_id : int;
      reason : string;
    }
  | Broker_unreachable of {
      client_order_id : string;
      reservation_id : int;
      reason : string;
    }
      (** Failure events carry [reservation_id] so the downstream
    rejection handler can find and release the earmark. *)

val forward_rejection_to_string : forward_rejection -> string

val reservation_id_of_rejection : forward_rejection -> int

val handle :
  place_order:place_order_port ->
  kind:Order.kind ->
  tif:Order.time_in_force ->
  client_order_id:string ->
  Engine.Portfolio.amount_reserved ->
  (order_forwarded, forward_rejection) Rop.t

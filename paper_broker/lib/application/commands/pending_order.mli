(** Application-layer persistence record for a working order.

    Wraps the pure-domain {!Paper_broker.Order.t} with the two
    correlation tokens paper_broker round-trips on every order
    lifecycle event:

    - [reservation_id] — opaque cross-BC token (Account's
      terminology, not interpreted here);
    - [correlation_id] — saga-instance identifier preserved from
      the originating {!Submit_order_command.t} so every
      downstream integration event (Order_accepted, Fill_observed,
      Order_cancelled, Order_rejected) carries the same value.

    paper_broker's Domain layer deliberately does not carry these
    tokens — they are application-layer concerns. The Application
    layer owns the correlation: it receives them on
    [submit_order_command], stores them alongside the
    {!Paper_broker.Order.t} in the {!Order_store.S}, and echoes
    them on every outbound integration event. *)

type t = private {
  order : Paper_broker.Order.t;
  reservation_id : int;
  correlation_id : string;
}

val make : order:Paper_broker.Order.t -> reservation_id:int -> correlation_id:string -> t

val id : t -> string
(** Primary key for the {!Order_store.S} — paper_broker's
    server-assigned order id. *)

val instrument : t -> Core.Instrument.t

val is_terminal : t -> bool
(** Convenience: [Paper_broker.Order.is_terminal t.order]. *)

val with_order : t -> Paper_broker.Order.t -> t
(** Replace the wrapped order, preserving the correlation tokens.
    Used after each {!Paper_broker.Order.apply_fill} /
    {!Paper_broker.Order.cancel} transition. *)

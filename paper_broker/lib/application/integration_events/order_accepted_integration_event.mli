(** Integration event: paper_broker accepted a freshly-submitted order
    into its working book. Published on
    [in-memory://broker.order-accepted] after a successful
    [submit_order_command_workflow].

    The downstream EMS saga transitions
    [Awaiting_reservation → Submitted] on this. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed from the inbound
          [submit_order_command]. *)
  reservation_id : int;
      (** Opaque correlation token supplied by the caller on
          [submit_order_command] and round-tripped on every order
          lifecycle event. paper_broker neither generates nor
          interprets it; the Account BC uses it to locate the
          reserved cash/position on [order_filled]. *)
  id : string;  (** paper_broker-assigned order id. *)
  client_order_id : string;  (** Caller-supplied client id (echoed). *)
  instrument : Paper_broker_queries.Instrument_view_model.t;
  side : string;  (** ["BUY"] | ["SELL"]. *)
  quantity : string;  (** Decimal string. *)
  created_ts : string;  (** ISO-8601. *)
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_accepted.t

val of_domain : correlation_id:string -> reservation_id:int -> domain -> t

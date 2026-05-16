(** Integration event: paper_broker accepted a freshly-submitted order
    into its working book. Published on
    [in-memory://broker.order-accepted] after a successful
    [submit_order_command_workflow].

    The downstream EMS saga transitions
    [Awaiting_reservation → Submitted] on this. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed from the inbound
          [submit_order_command]. Process metadata, not aggregate
          state. *)
  placement_id : int;
      (** Client's identifier of the order (FIX [clOrdID] role),
          sourced from the Domain {!Paper_broker.Order.Events.Order_accepted.placement_id}. *)
  id : string;  (** paper_broker-assigned order id (surrogate). *)
  instrument : Paper_broker_view_models.Instrument_view_model.t;
  side : string;  (** ["BUY"] | ["SELL"]. *)
  quantity : string;  (** Decimal string. *)
  created_ts : string;  (** ISO-8601. *)
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_accepted.t

val of_domain : correlation_id:string -> domain -> t

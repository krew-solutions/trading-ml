(** Integration event: a working order in paper_broker's book was
    cancelled. Published on [in-memory://broker.order-cancelled]
    after a successful [cancel_pending_order_command_workflow]. *)

type t = {
  correlation_id : string;  (** Saga-instance identifier of the cancel command. *)
  placement_id : int;
      (** Client's identifier of the order, sourced from the
          Domain event. Account releases the remaining reservation
          on this event. *)
  id : string;
  instrument : Paper_broker_view_models.Instrument_view_model.t;
  cancelled_ts : string;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Order_cancelled.t

val of_domain : correlation_id:string -> domain -> t

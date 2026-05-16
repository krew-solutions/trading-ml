(** PM-side mirror of {!Strategy_integration_events.Signal_detected_integration_event.t}.

    Structurally identical wire shape, owned by PM so the inbound ACL
    handler stays bus-agnostic. Per the [Place_order_pm] correlation
    chain the event itself is not part of a saga (alpha-mind lives
    above the order-placement saga, no correlation_id needed). *)

type t = {
  strategy_id : string;
  instrument : Portfolio_management_external_view_models.Instrument_view_model.t;
  direction : string;  (** ["UP"] | ["DOWN"] | ["FLAT"]. *)
  strength : float;
  price : string;  (** Decimal string. *)
  reason : string;
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]

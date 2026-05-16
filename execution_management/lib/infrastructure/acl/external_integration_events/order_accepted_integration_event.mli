(** Mirror of {!Broker_integration_events.Order_accepted_integration_event.t}. *)

type t = {
  correlation_id : string;
  reservation_id : int;
  broker_order : Execution_management_external_view_models.Order_view_model.t;
}
[@@deriving yojson]

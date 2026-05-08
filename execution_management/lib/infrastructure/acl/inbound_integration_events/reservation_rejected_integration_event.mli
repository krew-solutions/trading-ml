(** Mirror of {!Account_integration_events.Reservation_rejected_integration_event.t}. *)

type t = {
  correlation_id : string;
  side : string;
  instrument : Execution_management_inbound_queries.Instrument_view_model.t;
  quantity : string;
  reason : string;
}
[@@deriving yojson]

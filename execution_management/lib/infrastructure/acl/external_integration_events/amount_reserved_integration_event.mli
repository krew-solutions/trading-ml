(** Mirror of {!Account_integration_events.Amount_reserved_integration_event.t}. *)

type t = {
  correlation_id : string;
  reservation_id : int;
  side : string;
  instrument : Execution_management_external_view_models.Instrument_view_model.t;
  quantity : string;
  price : string;
  reserved_cash : string;
}
[@@deriving yojson]

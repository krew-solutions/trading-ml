type t = {
  correlation_id : string;
  side : string;
  instrument : Execution_management_external_view_models.Instrument_view_model.t;
  quantity : string;
  reason : string;
}
[@@deriving yojson]

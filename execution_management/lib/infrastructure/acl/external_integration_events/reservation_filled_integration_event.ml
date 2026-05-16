type t = {
  correlation_id : string;
  reservation_id : int;
  instrument : Execution_management_external_view_models.Instrument_view_model.t;
  side : string;
  filled_quantity : string;
  fill_price : string;
  fee : string;
  new_position_quantity : string;
  new_avg_price : string;
  new_cash : string;
}
[@@deriving yojson]

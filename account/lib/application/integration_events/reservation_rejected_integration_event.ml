type t = {
  correlation_id : string;
  side : string;
  instrument : Account_view_models.Instrument_view_model.t;
  quantity : string;
  reason : string;
}
[@@deriving yojson]

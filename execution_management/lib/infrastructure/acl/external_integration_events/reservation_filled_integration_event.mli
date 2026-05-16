(** EMS-side mirror of Account's [Reservation_filled_integration_event].

    Consumed by the kill-switch peak-equity tracker — only the
    [new_cash] field is used today (as an equity proxy until a
    mark-to-market feed lands).

    Wire-format DTO mirrors Account's outbound shape byte-for-byte;
    the type is duplicated, not imported, to keep BCs independent. *)

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

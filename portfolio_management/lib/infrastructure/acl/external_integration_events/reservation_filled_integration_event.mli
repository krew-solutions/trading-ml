(** PM-side mirror of Account's [Reservation_filled_integration_event].

    Carries the full transactional effect of a reservation maturing
    into a fill — both the new cash balance and the new position
    snapshot — in one atomic payload, so PM can commit them
    together via {!Commit_actual_fill_command} without ever exposing
    a transient state that violates [equity = cash + Σ qty × mark].

    Wire-format DTO mirrors Account's outbound shape byte-for-byte;
    the type is duplicated, not imported, to keep BCs independent. *)

type t = {
  correlation_id : string;
  reservation_id : int;
  instrument : Portfolio_management_external_view_models.Instrument_view_model.t;
  side : string;
  filled_quantity : string;
  fill_price : string;
  fee : string;
  new_position_quantity : string;
      (** Signed Decimal string; ["0"] denotes a closed position. *)
  new_avg_price : string;
      (** Non-negative Decimal string; ["0"] when
          [new_position_quantity] is ["0"]. *)
  new_cash : string;  (** Signed Decimal string; may be negative under margin. *)
}
[@@deriving yojson]

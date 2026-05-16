(** Integration event: a reservation matured into an actual fill.

    Published by {!Commit_fill_command_workflow} after
    {!Account.Portfolio.commit_fill} has settled the reservation.
    Carries the full transactional effect — both the new position
    snapshot and the new cash balance — in one atomic payload so
    consumers cannot observe a transient state that violates
    [equity = cash + Σ qty × mark].

    Subscribed by [pre_trade_risk]'s [Risk_view] (per-instrument
    exposure + cash buffer projection), [execution_management]'s
    [Kill_switch] (peak-equity / drawdown tracker), and the UI
    snapshot layer.

    DTO-shaped: primitives + nested instrument view model, no
    domain values. Decimals on the wire as canonical strings
    (ADR 0007). *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed from the upstream
          {!Commit_fill_command.t}. *)
  reservation_id : int;
  instrument : Account_view_models.Instrument_view_model.t;
  side : string;  (** ["BUY"] | ["SELL"]. *)
  filled_quantity : string;
      (** Actual fill quantity, decimal string. Always positive —
          sign is carried by [side]. *)
  fill_price : string;
  fee : string;
  new_position_quantity : string;
      (** Signed post-fill quantity, decimal string. Negative
          denotes a short, ["0"] denotes a closed position. *)
  new_avg_price : string;
      (** Post-fill VWAP of the surviving position. ["0"] when
          [new_position_quantity] is ["0"]. *)
  new_cash : string;  (** Post-fill cash balance, decimal string. *)
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Reservation_filled.t

val of_domain : correlation_id:string -> domain -> t

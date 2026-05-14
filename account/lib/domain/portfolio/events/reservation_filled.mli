(** Domain Event: a reservation matured into an actual fill.

    A fill atomically changes BOTH cash and position; the event
    carries the full transactional effect in one payload so
    downstream consumers (Risk_view in pre_trade_risk, the
    Kill_switch equity tracker in execution_management, UI
    snapshots) can apply both deltas together.

    Splitting this into [Position_changed] + [Cash_changed] would
    violate the accounting identity [equity = cash + Σ qty × mark]
    transiently — a consumer reading between the two publications
    would see a portfolio that is not internally consistent. For
    a risk-checking consumer that is a wrong decision, not a
    cosmetic glitch.

    Mirrors the existing aggregate-event idiom: [Amount_reserved]
    carries the entire reservation transaction, [Reservation_released]
    carries the entire release. [Reservation_filled] is the third
    member of the [Reservation] lifecycle — created, filled,
    released. *)

type t = {
  reservation_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  filled_quantity : Decimal.t;
      (** Actual fill quantity (always positive — sign is carried
          by [side]). *)
  fill_price : Decimal.t;  (** Actual fill price. *)
  fee : Decimal.t;  (** Actual fee, non-negative. *)
  new_position_quantity : Decimal.t;
      (** Signed post-fill quantity for [instrument]. Zero
          denotes a position that closed. *)
  new_avg_price : Decimal.t;
      (** Post-fill VWAP of the surviving position. Zero when
          [new_position_quantity] is zero. *)
  new_cash : Decimal.t;
      (** Post-fill cash balance. The full post-image, not a
          delta — consumers hold their own projection and want
          the authoritative new value. *)
}

(** Domain Event: a partial fill drew the reservation down,
    leaving an unfilled remainder still earmarked.

    Emitted by [Portfolio.commit_fill] when the actual filled
    quantity is strictly less than the reservation's remaining
    [cover_qty + open_qty]. The reservation stays in the
    ledger with reduced cover/open parts; [per_unit_collateral]
    is invariant across draws. The terminal draw — the one
    that brings both parts to zero — emits
    [Reservation_filled] instead.

    Like [Reservation_filled], this event carries the full
    post-image (new cash, new position, residual reserved
    cash) in one fact rather than per-field deltas. The same
    accounting-identity argument applies: a consumer that
    reads between split events would see a portfolio that
    fails [equity = cash + Σ qty × mark] transiently. For a
    risk-checking consumer (pre_trade_risk's drawdown
    circuit, ADR 0021) that is a wrong decision, not a
    cosmetic glitch.

    The [remaining_*] fields describe what is still earmarked
    after this draw — consumers reconstruct the live
    reservation snapshot without joining against an earlier
    [Amount_reserved] and replaying draws.

    See ADR 0028 for the progressive-drawdown contract this
    event closes. *)

type t = {
  reservation_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  drawn_quantity : Decimal.t;
      (** This draw's filled quantity (always positive — sign
          is carried by [side]). *)
  fill_price : Decimal.t;  (** This draw's actual fill price. *)
  fee : Decimal.t;  (** This draw's fee, non-negative. *)
  remaining_cover_qty : Decimal.t;
      (** Cover portion still earmarked after this draw. Zero
          when fully consumed by cover-first attribution. *)
  remaining_open_qty : Decimal.t;
      (** Open portion still earmarked after this draw. Drives
          the residual collateral block. *)
  remaining_reserved_cash : Decimal.t;
      (** [remaining_open_qty × per_unit_collateral]. Post-image
          of the cash block; [available_cash] grows by the delta
          this draw freed. *)
  new_position_quantity : Decimal.t;  (** Signed post-fill quantity for [instrument]. *)
  new_avg_price : Decimal.t;
      (** Post-fill VWAP. Zero when [new_position_quantity] is
          zero. *)
  new_cash : Decimal.t;
      (** Post-fill cash balance — full post-image, not a
          delta. *)
}

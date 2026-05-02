(** Pending trade Entity — qty/cash earmarked but not yet applied.
    Identified by [id]; lifecycle is
    [reserve → commit_partial_fill* → commit_fill | release]. Lives
    inside the [Portfolio] aggregate, so the parent aggregate is the
    sole transactional consistency boundary.

    A single reservation can carry both a {b cover} part (closes
    the opposite-side existing position — Sell on a long, Buy on a
    short) and an {b open} part (opens or grows a same-side
    position). Splitting them is necessary because they have
    different accounting consequences:

    - [cover_qty] consumes available position quantity but does
      not block cash;
    - [open_qty] does not consume position quantity but blocks
      collateral cash via [per_unit_collateral].

    Partial fills are attributed cover-first: each fill depletes
    [cover_qty] before [open_qty] (the latter is what actually
    releases collateral as it commits). *)

(*@ function dec_raw (d : Decimal.t) : integer *)
(** Local alias for [Decimal.t]'s scaled-integer projection. See the
    matching note in [core/candle.mli] — Gospel 0.3.1 doesn't carry
    [model] declarations across files, so each consumer restates it. *)

type t = {
  id : int;
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  cover_qty : Decimal.t;
      (** Portion that closes the opposite-side existing position.
          For Buy: closes a short. For Sell: closes a long. Always
          [≥ 0]. *)
  open_qty : Decimal.t;
      (** Portion that opens or grows a same-side position. For
          Buy: adds to a long. For Sell: opens or extends a short.
          Always [≥ 0]. *)
  per_unit_collateral : Decimal.t;
      (** Per-unit cash impact of the [open_qty] part on settlement.
          For Buy: [price × (1 + slippage_buffer) + price × fee_rate].
          For Sell-open: [price × margin_pct]. For Sell-cover-only
          reservations (where [open_qty = 0]): [Decimal.zero]. Set
          at construction and never changes — partial-fill proration
          scales by remaining [open_qty]. *)
}
(** Invariant: [cover_qty ≥ 0] and [open_qty ≥ 0]. The total
    remaining quantity is [cover_qty + open_qty]; total reserved
    cash is [open_qty × per_unit_collateral]. *)

val quantity : t -> Decimal.t
(** [cover_qty + open_qty] — total remaining reserved quantity. *)

val reserved_cash : t -> Decimal.t
(** [open_qty × per_unit_collateral]. Earmarked cash still pending
    (drops as the open portion of a partial fill commits). Cover
    portion does not block cash; closing an existing position is
    not a leveraged operation. *)

val reserved_qty : t -> Decimal.t
(** [cover_qty] for a Sell reservation, [Decimal.zero] for a Buy.
    Position-quantity earmark locking out further sells against the
    same long position. The open portion is unbounded by qty (a
    short can grow without consuming long-side qty), so it is not
    counted here. *)
(*@ q = reserved_qty r
    ensures dec_raw q =
            (match r.side with
             | Core.Side.Buy -> 0
             | Core.Side.Sell -> dec_raw r.cover_qty) *)

val per_unit_collateral_for_buy :
  price:Decimal.t -> slippage_buffer:Decimal.t -> fee_rate:Decimal.t -> Decimal.t
(** Per-unit cash for a Buy reservation: includes the slippage
    buffer and a fee estimate, identical to the previous
    pre-margin-model formula. Buy stays cash-bounded; the margin
    model does not grant Buy a haircut-based buying power expansion
    in this round. *)

val per_unit_collateral_for_sell_open :
  price:Decimal.t -> margin_pct:Decimal.t -> Decimal.t
(** Per-unit cash for the open portion of a Sell reservation:
    [price × margin_pct]. The cover portion of a Sell never uses
    this — closing a long does not require collateral. *)

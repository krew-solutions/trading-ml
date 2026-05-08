(** Aggregate root: pre_trade_risk's view of one book's currently-held
    cash and positions, used as input to {!Assessment.assess}.

    Conceptually a slimmed-down portfolio: we only need the inputs the
    pre-trade gate consults (cash floor, gross exposure, leverage), so
    no reservation tracking, no realized-PnL accounting, no margin
    policy. Account remains the system of record for those — Risk_view
    is a derived projection fed by Account's outbound integration
    events.

    Invariants:

    - per-instrument single-valuedness: at most one
      {!Values.Position_snapshot.t} per instrument;
    - delta accumulation: [position(after) = new_qty] from the
      upstream event (the upstream is authoritative on the post-state,
      we record its [delta_qty] for audit);
    - zero-qty pruning: [new_qty = 0] removes the entry entirely;
    - cash sign tolerance: [cash] may be negative (margin); the
      aggregate does not validate the sign — that is upstream's
      concern.

    Mirrors the shape of {!Portfolio_management.Actual_portfolio} —
    deliberate parallel; both are downstream projections of the same
    upstream Account events, with different consumers and different
    invariants. *)

module Values : module type of Values
(** Re-exports of peer subdirs. *)

module Events : module type of Events

type t

val empty : Common.Book_id.t -> t

val book_id : t -> Common.Book_id.t
val cash : t -> Decimal.t

val position : t -> Core.Instrument.t -> Decimal.t
(** Signed position quantity; [Decimal.zero] if absent. *)

val positions : t -> Values.Position_snapshot.t list
(** Snapshot view, in deterministic instrument-compare order. *)

val apply_position_change :
  t ->
  instrument:Core.Instrument.t ->
  delta_qty:Decimal.t ->
  new_qty:Decimal.t ->
  avg_price:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Position_recorded.t

val apply_cash_change :
  t ->
  delta:Decimal.t ->
  new_balance:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Cash_recorded.t

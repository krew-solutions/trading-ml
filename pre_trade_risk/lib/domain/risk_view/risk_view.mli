(** Aggregate root: pre_trade_risk's view of one book's currently-held
    cash and positions, used as input to {!Assessment.assess}.

    Conceptually a slimmed-down portfolio: we only need the inputs the
    pre-trade gate consults (cash floor, gross exposure, leverage), so
    no reservation tracking, no realized-PnL accounting, no margin
    policy. Account remains the system of record for those —
    [Risk_view] is pre_trade_risk's own model with its own invariants,
    synchronised from Account's outbound integration events through
    the ACL.

    Invariants:

    - per-instrument single-valuedness: at most one
      {!Values.Position_snapshot.t} per instrument;
    - zero-qty pruning: [new_position_quantity = 0] removes the entry
      entirely;
    - cash sign tolerance: [cash] may be negative (margin); the
      aggregate does not validate the sign — that is upstream's
      concern.

    Mirrors the shape of {!Portfolio_management.Actual_portfolio} —
    deliberate parallel; both aggregates commit the same upstream
    Account fill into their own models, with different consumers and
    different invariants. The cash and position sides advance together via a
    single [commit_fill], preserving the [equity = cash +
    Σ qty × mark] invariant across consumer observation. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

module Values : module type of Values
(** Re-exports of peer subdirs. *)

module Events : module type of Events

type t

val empty : Common.Book_id.t -> t
(*@ v = empty b
    ensures dec_raw (cash v) = 0
    ensures positions v = [] *)

val book_id : t -> Common.Book_id.t
val cash : t -> Decimal.t

val position : t -> Core.Instrument.t -> Decimal.t
(** Signed position quantity; [Decimal.zero] if absent. *)

val positions : t -> Values.Position_snapshot.t list
(** Snapshot view, in deterministic instrument-compare order. *)

val commit_fill :
  t ->
  instrument:Core.Instrument.t ->
  new_position_quantity:Decimal.t ->
  new_avg_price:Decimal.t ->
  new_cash:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Fill_recorded.t
(** Atomic post-fill commit: replaces the entry for [instrument] with
    the new [new_position_quantity] / [new_avg_price] and replaces
    [cash] with [new_cash], emitting a single [Fill_recorded] event.
    If [new_position_quantity = Decimal.zero], the entry is removed. *)
(*@ r = commit_fill v ~instrument ~new_position_quantity ~new_avg_price ~new_cash ~occurred_at
    ensures match r with (v', _) ->
              dec_raw (cash v') = dec_raw new_cash
              /\ book_id v' = book_id v *)

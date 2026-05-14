(** Aggregate root: PM's model of the *observed* state of a book —
    the second perspective on Portfolio, paired with [Target_portfolio]
    (the *intended* state). Both are first-class domain models in this
    BC; the difference is which aspect of the same concept they
    capture, not whether they bear invariants.

    Invariants enforced here:

    - per-instrument single-valuedness: at most one entry per
      instrument;
    - zero-qty pruning: a commit that drives [new_position_quantity]
      to zero removes the entry from [positions], so [position]
      yields [Decimal.zero] for an absent instrument by the same path
      as for a never-held one;
    - cash sign tolerance: [cash] can be negative (margin); commits
      do not validate the sign — that is upstream's concern.

    Updated by {!Commit_actual_fill_command} — never by direct
    mutation. PM never reads [Account.Portfolio] directly; the
    observed state arrives as a [Reservation_filled] integration
    event from Account and is re-modelled here in PM's vocabulary.
    The commit carries the post-fill [cash], [position_quantity] and
    [avg_price] together, preserving the equity invariant
    ([equity = cash + Σ qty × mark]) across consumer observation. *)

module Values : module type of Values
(** Re-exports of peer subdirs. *)

module Events : module type of Events

type t

val empty : Common.Book_id.t -> t

val book_id : t -> Common.Book_id.t

val cash : t -> Decimal.t

val position : t -> Core.Instrument.t -> Decimal.t
(** Signed position quantity; [Decimal.zero] if absent. *)

val positions : t -> Values.Actual_position.t list
(** Snapshot view, in deterministic instrument-compare order. *)

val commit_fill :
  t ->
  instrument:Core.Instrument.t ->
  new_position_quantity:Decimal.t ->
  new_avg_price:Decimal.t ->
  new_cash:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Actual_fill_committed.t
(** Atomic post-fill commit: replaces the entry for [instrument] with
    the new [new_position_quantity] / [new_avg_price] and replaces
    [cash] with [new_cash], emitting a single
    [Actual_fill_committed] event. If
    [new_position_quantity = Decimal.zero], the entry is removed
    from [positions]. Cash and position move together; consumers
    never see a transiently inconsistent (cash-only or position-only)
    state. *)

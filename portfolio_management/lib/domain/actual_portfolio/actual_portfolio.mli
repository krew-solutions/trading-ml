(** Aggregate root: PM's model of the *observed* state of a book —
    the second perspective on Portfolio, paired with [Target_portfolio]
    (the *intended* state). Both are first-class domain models in this
    BC; the difference is which aspect of the same concept they
    capture, not whether they bear invariants.

    Invariants enforced here:

    - per-instrument single-valuedness: at most one entry per
      instrument. The aggregate records [delta_qty] applied on top of
      [new_qty] from the upstream event, but the canonical answer to
      "what's my current position" is a single [Decimal.t] per
      instrument;
    - delta accumulation: [position(after) = position(before) +
      delta_qty] for every applied change;
    - zero-qty pruning: an apply that drives [new_qty] to zero removes
      the entry from [positions], so [position] yields [Decimal.zero]
      for an absent instrument by the same path as for a never-held
      one;
    - cash sign tolerance: [cash] can be negative (margin); applies
      do not validate the sign — that is upstream's concern.

    Updated by {!Change_position_command} and
    {!Change_cash_command} — never by direct mutation. PM
    never reads [Account.Portfolio] directly; the observed state
    arrives as integration events and is re-modelled here in PM's
    vocabulary. *)

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

val apply_position_change :
  t ->
  instrument:Core.Instrument.t ->
  delta_qty:Decimal.t ->
  new_qty:Decimal.t ->
  avg_price:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Actual_position_changed.t
(** Accumulating apply: the current position for [instrument] becomes
    [new_qty] (not [previous + delta_qty] — the upstream event is
    authoritative on the post-state). [delta_qty] is recorded on the
    emitted event for downstream subscribers that want the change
    rather than the new value. If [new_qty = 0], the entry is removed
    from [positions]. *)

val apply_cash_change :
  t ->
  delta:Decimal.t ->
  new_balance:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Actual_cash_changed.t
(** Accumulating apply: [cash] becomes [new_balance]; [delta] is
    recorded on the emitted event. *)

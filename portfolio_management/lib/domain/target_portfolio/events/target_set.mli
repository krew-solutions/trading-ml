(** Domain Event: the target portfolio for [book_id] was updated.
    Emitted by {!Target_portfolio.apply_proposal} on every successful
    proposal application. Past-tense name follows the project
    convention (events are facts about what happened, commands take
    an imperative).

    The [changed] field carries the per-instrument deltas observed by
    the aggregate when the proposal was applied — instruments whose
    target_qty was added, replaced, or set to zero. An empty [changed]
    list is permitted: it represents an idempotent re-application of
    the current target. Downstream subscribers can short-circuit on
    that case rather than re-running the reconciler. *)

type change = {
  instrument : Core.Instrument.t;
  previous_qty : Decimal.t;  (** signed; [Decimal.zero] if instrument was absent *)
  new_qty : Decimal.t;  (** signed; [Decimal.zero] when zeroed out *)
}

type t = {
  book_id : Shared.Book_id.t;
  source : string;
  proposed_at : int64;
  changed : change list;
}

(** Pure domain service: compute the trade list that takes [actual] to
    [target]. Strictly per-book — caller is responsible for ensuring
    the two aggregates carry the same [Book_id.t] (the function
    propagates the target's book_id onto every emitted intent).

    Idempotent in the sense that {!diff} on a [target / actual] pair
    where [actual] already realises [target] returns []. The companion
    Why3 module states this as a goal. *)

module Events : module type of Events
(** Re-exports of peer subdirs. *)

val diff :
  target:Target_portfolio.t -> actual:Actual_portfolio.t -> Shared.Trade_intent.t list
(** Returned list is sorted by {!Core.Instrument.compare} for
    deterministic downstream reasoning. Each emitted intent carries
    [book_id] copied from the target, [side] derived from the sign
    of [target_qty − actual_qty], and [quantity] equal to
    [|target_qty − actual_qty|]. Instruments where the difference is
    zero are absent from the result (no zero-quantity intents are
    emitted). *)

val diff_with_event :
  target:Target_portfolio.t ->
  actual:Actual_portfolio.t ->
  computed_at:int64 ->
  Shared.Trade_intent.t list * Events.Trades_planned.t
(** Same as {!diff} but also packages the result into a
    [Trades_planned] domain event with the supplied timestamp. *)

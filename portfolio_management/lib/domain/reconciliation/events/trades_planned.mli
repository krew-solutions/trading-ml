(** Domain Event: the reconciler computed a trade list for [book_id].
    Emitted by {!Reconciliation.diff_with_event} (the event-emitting
    counterpart of [Reconciliation.diff]).

    Pure data carrier; past-tense name. An empty [trades] list is
    legitimate — it represents "actual already matches target", and
    downstream subscribers can treat it as a signal of completion. *)

type t = {
  book_id : Shared.Book_id.t;
  trades : Shared.Trade_intent.t list;
  computed_at : int64;
}

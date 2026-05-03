(** Integration event: the reconciler computed a trade list for
    [book_id]. Published by {!Reconcile_command_workflow}.

    An empty [trades] list is legitimate — it represents "actual
    already matches target", and downstream consumers can treat it
    as a signal of completion.

    DTO-shaped: primitives + nested view model. *)

type t = {
  book_id : string;
  trades : Portfolio_management_queries.Trade_intent_view_model.t list;
  computed_at : int64;
}
[@@deriving yojson]

type domain = Portfolio_management.Reconciliation.Events.Trades_planned.t

val of_domain : domain -> t

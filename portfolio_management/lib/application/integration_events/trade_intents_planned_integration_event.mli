(** Integration event: the reconciler computed a trade list for
    [book_id]. Published by {!Reconcile_command_workflow}.

    An empty [trades] list is legitimate — it represents "actual
    already matches target", and downstream consumers can treat it
    as a signal of completion.

    DTO-shaped: primitives + nested view model. *)

type leg = {
  correlation_id : string;
      (** Saga-instance identifier minted per trade leg at IE
        construction time. Each leg of a multi-trade plan starts an
        independent {!Place_order_pm} saga; downstream BCs
        ([pre_trade_risk], [execution_management], Account, Broker)
        echo this id verbatim through their commands and IEs so the
        Process Manager can route the eventual venue acks back to
        the originating leg. UUID v4. *)
  intent : Portfolio_management_view_models.Trade_intent_view_model.t;
}
[@@deriving yojson]

type t = { book_id : string; trades : leg list; computed_at : string  (** ISO-8601 *) }
[@@deriving yojson]

type domain = Portfolio_management.Reconciliation.Events.Trades_planned.t

val of_domain : domain -> t

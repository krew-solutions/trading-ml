(** Integration event: Portfolio Management updated the target
    portfolio for [book_id].

    Published by {!Set_target_command_workflow} after
    {!Portfolio_management.Target_portfolio.apply_proposal} succeeds.
    [book_id] is the cross-BC partition key — downstream consumers
    (execution / reconciler) filter on it.

    DTO-shaped: primitives + nested view model, no domain values.
    [@@deriving yojson] auto-generates the on-wire format. *)

type change = {
  instrument : Portfolio_management_queries.Instrument_view_model.t;
  previous_qty : string;  (** signed Decimal string *)
  new_qty : string;
}
[@@deriving yojson]

type t = { book_id : string; source : string; proposed_at : int64; changed : change list }
[@@deriving yojson]

type domain = Portfolio_management.Target_portfolio.Events.Target_set.t

val of_domain : domain -> t

(** Inbound command to the Portfolio Management BC: "replace the
    target portfolio for [book_id] with the supplied positions."

    Wire-format DTO — primitives only, no domain values. [proposed_at]
    is an ISO-8601 timestamp parsed by the handler. [target_qty] is
    a signed Decimal string (positive long, negative short, zero flat).

    Triggered by external entries only: operator override via PM
    HTTP routes (planned), CLI rebalance commands (planned), or
    cross-BC imports (e.g. a third-party advisor pushing target
    portfolios). PM-internal construction policies do NOT route
    through this command — pair_mean_reversion applies proposals via
    {!Apply_bar_command_workflow}; alpha_view applies via the
    [Direction_changed] domain-event handler. Both reach
    {!Portfolio_management.Target_portfolio.apply_proposal} directly
    on the success path of their own workflows. *)

type position = {
  instrument : string;  (** [TICKER@MIC[/BOARD]] *)
  target_qty : string;  (** signed Decimal string *)
}
[@@deriving yojson]

type t = {
  book_id : string;
  source : string;
  proposed_at : string;  (** ISO-8601 *)
  positions : position list;
}
[@@deriving yojson]

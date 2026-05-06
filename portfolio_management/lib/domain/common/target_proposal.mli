(** Output of a portfolio_construction policy: the set of leg-level
    target positions it wants the book to hold from now on. Carries
    [book_id] so the consuming [Target_portfolio] aggregate routes it
    to the right book; [source] names the policy that produced it
    (e.g. ["pair_mean_reversion"]) for audit; [proposed_at] is the
    epoch second at which the policy emitted it.

    Convention: every [position] in [positions] carries the same
    [book_id] as the proposal itself. The aggregate verifies this on
    [apply_proposal]. *)

type t = {
  book_id : Book_id.t;
  positions : Target_position.t list;
  source : string;
  proposed_at : int64;
}

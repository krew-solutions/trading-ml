(** Domain Event: pair_kalman_mean_reversion produced a target
    proposal for its book. Emitted by
    {!Pair_kalman_mean_reversion.on_bar} on every direction change
    (Flat → Long/Short_spread; Long/Short → Flat). The event
    carries the proposal itself plus the innovation z-score that
    triggered it for audit.

    Structurally identical to
    {!Pair_mean_reversion.Events.Target_proposed}; kept as a
    distinct event type so audit logs name the policy that
    filed the target. *)

type t = { proposal : Common.Target_proposal.t; z : Common.Z_score.t }

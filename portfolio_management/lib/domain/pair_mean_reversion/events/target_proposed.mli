(** Domain Event: pair_mean_reversion produced a target proposal for
    its book. Emitted by {!Pair_mean_reversion.on_bar} on every
    direction change (Flat → Long/Short_spread; Long/Short → Flat).
    The event carries the proposal itself plus the z-score that
    triggered it for audit. *)

type t = { proposal : Shared.Target_proposal.t; z : Shared.Z_score.t }

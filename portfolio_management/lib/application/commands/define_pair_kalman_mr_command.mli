(** Inbound CQRS command to (re)define a
    {!Portfolio_management.Pair_kalman_mean_reversion} policy state
    for one book. Persists the initialised state into the per-book
    Kalman registry consulted by {!Apply_bar_command_workflow}.

    Parallel to {!Define_pair_mr_command} but for the adaptive-β
    variant: the operator configures the DLM filter (discount,
    observation noise, prior, burn-in) instead of supplying a
    static hedge ratio.

    Re-issuing for the same [(book_id, pair)] replaces the state
    (resets the posterior to the prior, clears innovation history,
    and direction to Flat); this matches the operator intent
    "redefine the policy with these parameters from now on". *)

include module type of struct
  include Define_pair_kalman_mr_command_t
  include Define_pair_kalman_mr_command_j
end

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

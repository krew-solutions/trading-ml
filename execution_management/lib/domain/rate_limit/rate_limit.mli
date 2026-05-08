(** Aggregate-style rolling-window rate limit. Tracks a list of
    submission timestamps (epoch seconds, monotonic) and answers
    {!try_acquire} based on how many fall within the configured
    window.

    Pure: no clock inside; the caller passes [now] explicitly so
    tests can drive the state deterministically. *)

module Values : module type of Values

type t

val make : config:Values.Rate_limit_config.t -> t
val config : t -> Values.Rate_limit_config.t

val try_acquire : t -> now:float -> [ `Allow of t | `Throttle ]
(** [try_acquire ~now] prunes entries older than
    [now − window_seconds] and, if the resulting count is below
    [max_orders], records [now] and returns [`Allow t']. Otherwise
    [`Throttle] without recording — the caller is expected to drop
    or queue the submission. *)

val active_count : t -> now:float -> int
(** Diagnostic: how many recorded timestamps fall inside the trailing
    window at [now]. *)

(** Configurable kill-switch threshold expressed as a fraction in
    [0, 1]: trip when [(peak − current) / peak > max_drawdown_pct].

    [0.0] means "never trip" (disabled). [1.0] means "trip on
    anything below peak" (also degenerate). Typical production
    values are [0.10] .. [0.20]. *)

type t = private float

val of_float : float -> t
(** Raises [Invalid_argument] when outside [0.0; 1.0]. *)

val to_float : t -> float

val disabled : t
(** [0.0]; convenience for tests / synthetic deployments. *)

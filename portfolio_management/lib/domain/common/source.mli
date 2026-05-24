(** Origin of a {!Construction_intent.t}: the construction
    policy that decided to express a target.

    Modelled as a tagged sum so the type witnesses *which kind*
    of policy emitted the intent — not a free-form string. Each
    variant carries the identifying handle of the producer so
    downstream auditing can route by origin without parsing
    serialised tags.

    The wire boundary (integration events, ATD contracts) flattens
    this to a string via {!to_string}; the domain side preserves
    the discrimination. *)

type t =
  | Alpha_view of Alpha_source_id.t
      (** A single-asset directional bias from an upstream alpha
          source; produces a [Scalar] intent. *)
  | Pair_mean_reversion of Pair.t
      (** A coupled two-leg construction with a β-hedge invariant
          and a {b static} operator-supplied β; produces a
          [Coupled] intent. *)
  | Pair_kalman_mean_reversion of Pair.t
      (** A coupled two-leg construction with a β-hedge invariant
          and an {b adaptive} β estimated online via a Harrison-West
          DLM Kalman filter; produces a [Coupled] intent of the
          same shape as {!Pair_mean_reversion}, but provenanced
          separately so [Risk_config.authorises] can structurally
          distinguish a Kalman-driven book from a static one and
          downstream audit can name the policy that filed the
          target. *)

val to_string : t -> string
(** Stable rendering for logs, audit, and the wire boundary.
    ["alpha_view:<id>"], ["pair_mean_reversion:<a>|<b>"], or
    ["pair_kalman_mean_reversion:<a>|<b>"]. *)

val equal : t -> t -> bool

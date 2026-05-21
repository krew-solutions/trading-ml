(** VWAP — Volume-Weighted Average Price — parameters.

    Schedule mirrors TWAP's time grid ([n_slices] over
    [window_seconds] from [start_at]), but slice quantities follow
    the [volume_profile] weights instead of being equal. The
    profile is supplied as a static array — VWAP-with-realtime-
    feed is a later refinement (would consume [Volume_bar] inputs
    similarly to POV).

    Invariants:
    - [n_slices > 0], [window_seconds > 0];
    - [List.length volume_profile = n_slices];
    - each weight ≥ 0;
    - [Σ weights > 0] (otherwise nothing gets emitted; degenerate
      and rejected at construction). *)

type t = private {
  n_slices : int;
  window_seconds : int;
  start_at : int64;
  volume_profile : float list;
}

val make :
  n_slices:int -> window_seconds:int -> start_at:int64 -> volume_profile:float list -> t
(** Raises [Invalid_argument] on any invariant violation. The
    weights are normalised internally — callers may pass raw
    proportions (e.g. [[1.0; 3.0; 4.0; 2.0]]) without
    pre-normalising. *)

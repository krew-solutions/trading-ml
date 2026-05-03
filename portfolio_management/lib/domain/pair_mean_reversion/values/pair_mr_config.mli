(** Configuration for {!Pair_mean_reversion}.

    Invariants enforced at construction:
    - [window > 0];
    - [|z_entry| > |z_exit|]: the entry threshold must be stricter
      than the exit threshold so that a position opened on a z-cross
      doesn't immediately close on the same bar (hysteresis);
    - [notional > 0]. *)

type t = private {
  book_id : Shared.Book_id.t;
  pair : Shared.Pair.t;
  hedge_ratio : Shared.Hedge_ratio.t;
  window : int;
  z_entry : Shared.Z_score.t;
  z_exit : Shared.Z_score.t;
  notional : Decimal.t;
}

val make :
  book_id:Shared.Book_id.t ->
  pair:Shared.Pair.t ->
  hedge_ratio:Shared.Hedge_ratio.t ->
  window:int ->
  z_entry:Shared.Z_score.t ->
  z_exit:Shared.Z_score.t ->
  notional:Decimal.t ->
  t
(** Raises [Invalid_argument] on a violation. *)

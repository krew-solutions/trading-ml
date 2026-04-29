(** Feature extraction for the learned composite policy.
    Produces a float array from child signals + market context. *)

open Core

val n_features : n_children:int -> int

val extract :
  signals:Signal.t list ->
  candle:Candle.t ->
  recent_closes:float list ->
  recent_volumes:float list ->
  float array

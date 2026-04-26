(** Offline walk-forward trainer for the Learned composite policy.
    Runs child strategies over historical candles, collects
    (features, outcome) pairs, and trains a logistic model with a
    70/30 train/validation split. No future information leaks. *)

open Core

type result = {
  weights : float array;
  train_loss : float;
  val_loss : float;
  n_train : int;
  n_val : int;
}

val train :
  children:Strategies.Strategy.t list ->
  candles:Candle.t list ->
  ?lookahead:int ->
  ?epochs:int ->
  ?lr:float ->
  ?l2:float ->
  ?context_window:int ->
  unit ->
  result

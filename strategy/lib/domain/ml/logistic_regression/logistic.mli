(** Minimal logistic regression: sigmoid, prediction, and online SGD.
    No external dependencies — pure float arithmetic. *)

type t

val make : n_features:int -> ?lr:float -> ?l2:float -> unit -> t
val n_features : t -> int

val sigmoid : float -> float
val predict : t -> float array -> float

val sgd_step : t -> float array -> float -> unit
val train : t -> epochs:int -> (float array * float) list -> float

val export_weights : t -> float array
val of_weights : ?lr:float -> ?l2:float -> float array -> t

val to_json : t -> Yojson.Safe.t
(** Serialisation helpers. The on-disk form is a small JSON object
    carrying [weights] plus the hyperparameters [lr] / [l2] so a
    reconstructed model can resume training under the same
    schedule (not just inference). Format:
    {v
    { "weights": [b, w1, w2, …],
      "lr":      0.01,
      "l2":      1e-4 }
    v}
    Unknown fields are ignored; missing [lr]/[l2] fall back to the
    [Logistic.make] defaults.

    Weights are the whole model — a handful of scalars — so mtime
    watchers and atomic-rename ceremony are overkill. Restart the
    process to pick up new weights. *)

val of_json : Yojson.Safe.t -> t

val to_file : path:string -> t -> unit
val of_file : string -> t

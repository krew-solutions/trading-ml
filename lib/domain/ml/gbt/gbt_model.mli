(** Gradient-boosted-tree inference.

    Parses a LightGBM native text dump (the [save_model] output) and
    runs per-sample predictions in pure OCaml. Training lives
    elsewhere (Python / lightgbm); this module is inference-only so
    the production runtime has zero ML dependencies.

    Scope: numeric features, binary classification / multiclass
    softmax / regression. Categorical feature splits, linear-tree
    leaves (LightGBM 4.x linear_tree) and quantized trees are not
    supported — the parser will reject or mis-handle them. If we
    ever need them, extend here, don't bolt them into callers. *)

type objective =
  | Regression    (** Raw tree-sum is the prediction. *)
  | Binary        (** Sigmoid on tree-sum → P(class=1). *)
  | Multiclass of int
    (** Softmax over per-class raw scores. For [num_class = k] the
        model carries [k] trees per boosting iteration, interleaved
        in [trees]: tree at position [i] contributes to class
        [i mod k]. *)

type tree
(** Opaque binary tree. Internal nodes carry [(split_feature,
    threshold, left_child, right_child, default_left)]; leaves
    carry a single float. Children encoded LightGBM-style:
    non-negative = internal-node index, negative = leaf index
    (decode as [- child - 1]). *)

type t = {
  objective : objective;
  num_features : int;
  feature_names : string array;
  trees : tree array;
}

val of_text : string -> t
(** Parse a LightGBM text-format model (contents of [save_model(path)]).
    Raises [Invalid_argument] on malformed input or unsupported
    features (categorical splits, linear leaves). *)

val of_file : string -> t
(** Convenience wrapper around {!of_text} that reads [path]. *)

val predict : t -> features:float array -> float
(** Single-sample prediction. Return value depends on objective:
    - [Regression] → raw value
    - [Binary] → P(class=1)
    - [Multiclass k] → probability of the argmax class. Use
      {!predict_class_probs} when the full distribution is needed.

    [features] must have length [num_features]; missing values
    are expressed as [Float.nan] and traverse using each split's
    stored default direction. *)

val predict_class_probs : t -> features:float array -> float array
(** Full per-class probability vector.
    - [Binary] → [| P(class=0); P(class=1) |]
    - [Multiclass k] → softmax probabilities, length [k]
    - [Regression] → raises [Invalid_argument]. *)

val raw_score : t -> features:float array -> float array
(** Pre-activation sum of tree outputs per class; length = 1 for
    [Regression] / [Binary], [k] for [Multiclass k]. Exposed for
    diagnostics / calibration tuning. *)

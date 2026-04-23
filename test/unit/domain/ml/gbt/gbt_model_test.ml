(** Unit tests for {!Gbt.Gbt_model}.

    Test fixture is a hand-authored LightGBM text dump — smaller
    and more deterministic than anything lightgbm.train would
    produce, but matches the format exactly: same header keys, same
    tree-section shape, same child-encoding convention. *)

let sample_binary = {|tree
version=v3
num_class=1
num_tree_per_iteration=1
label_index=0
max_feature_idx=1
objective=binary sigmoid:1
feature_names=x0 x1
feature_infos=[-1:1] [-1:1]
tree_sizes=100 100

Tree=0
num_leaves=3
num_cat=0
split_feature=0 1
split_gain=0.1 0.05
threshold=0.5 1.5
decision_type=2 2
left_child=1 -1
right_child=-2 -3
leaf_value=-0.3 0.2 0.5
leaf_weight=100 100 100
leaf_count=100 100 100
internal_value=0.0 0.1
internal_weight=300 200
internal_count=300 200
is_linear=0
shrinkage=1


Tree=1
num_leaves=2
num_cat=0
split_feature=0
split_gain=0.08
threshold=-0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.1 0.15
leaf_weight=150 150
leaf_count=150 150
internal_value=0.0
internal_weight=300
internal_count=300
is_linear=0
shrinkage=1


end of trees

feature_importances:
x0=2
x1=1
|}

(** Tree 0 layout:
                         split f0 ≤ 0.5
                        /              \
              split f1 ≤ 1.5        leaf 1 = 0.20
              /         \
       leaf 0 = -0.30   leaf 2 = 0.50

    Tree 1 layout:
                    split f0 ≤ -0.5
                    /              \
              leaf 0 = -0.10    leaf 1 = 0.15

    Combined raw score and sigmoid per test input: see each assertion. *)

let sigmoid x = 1.0 /. (1.0 +. exp (-. x))

let test_parses_header () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  Alcotest.(check int) "num_features" 2 m.num_features;
  Alcotest.(check (array string)) "feature_names"
    [| "x0"; "x1" |] m.feature_names;
  Alcotest.(check int) "num_trees" 2 (Array.length m.trees);
  Alcotest.(check bool) "objective is Binary" true
    (m.objective = Binary)

let test_binary_predict_basic () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  (* f0=0.3 → tree0 left → f1=2.0 → right → leaf2 = 0.50
     f0=0.3 → tree1 right → leaf1 = 0.15
     raw = 0.65, sigmoid ≈ 0.6570 *)
  let p = Gbt.Gbt_model.predict m ~features:[| 0.3; 2.0 |] in
  Alcotest.(check (float 1e-4)) "P(1) at (0.3, 2.0)"
    (sigmoid 0.65) p

let test_binary_predict_left_branch () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  (* f0=0.3 → tree0 left → f1=1.0 → left → leaf0 = -0.30
     f0=0.3 → tree1 right → leaf1 = 0.15
     raw = -0.15, sigmoid ≈ 0.4626 *)
  let p = Gbt.Gbt_model.predict m ~features:[| 0.3; 1.0 |] in
  Alcotest.(check (float 1e-4)) "P(1) at (0.3, 1.0)"
    (sigmoid (-0.15)) p

let test_binary_predict_right_branch () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  (* f0=1.0 → tree0 right → leaf1 = 0.20
     f0=1.0 → tree1 right → leaf1 = 0.15
     raw = 0.35, sigmoid ≈ 0.5866 *)
  let p = Gbt.Gbt_model.predict m ~features:[| 1.0; 0.0 |] in
  Alcotest.(check (float 1e-4)) "P(1) at (1.0, 0.0)"
    (sigmoid 0.35) p

let test_nan_uses_default_left () =
  (* decision_type=2 → default_left = true. NaN at f0 in tree 0 should
     traverse to the left child (node 1), then branch on f1. *)
  let m = Gbt.Gbt_model.of_text sample_binary in
  (* f0=NaN → tree0 left → f1=2.0 → right → leaf2 = 0.50
     f0=NaN → tree1 left → leaf0 = -0.10
     raw = 0.40, sigmoid ≈ 0.5987 *)
  let p = Gbt.Gbt_model.predict m ~features:[| Float.nan; 2.0 |] in
  Alcotest.(check (float 1e-4)) "NaN traverses default_left"
    (sigmoid 0.40) p

let test_predict_class_probs_binary () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  let probs = Gbt.Gbt_model.predict_class_probs m
    ~features:[| 0.3; 2.0 |] in
  Alcotest.(check int) "two probs" 2 (Array.length probs);
  Alcotest.(check (float 1e-6)) "sums to 1"
    1.0 (probs.(0) +. probs.(1));
  Alcotest.(check (float 1e-4)) "P(1) matches predict"
    (sigmoid 0.65) probs.(1)

let test_raw_score_shape () =
  let m = Gbt.Gbt_model.of_text sample_binary in
  let raw = Gbt.Gbt_model.raw_score m ~features:[| 0.3; 2.0 |] in
  Alcotest.(check int) "binary raw len=1" 1 (Array.length raw);
  Alcotest.(check (float 1e-6)) "raw = 0.65" 0.65 raw.(0)

let test_rejects_categorical_split () =
  (* Minimal tree with decision_type=1 (bit 0 set) = categorical. *)
  let bad = {|tree
version=v3
num_class=1
num_tree_per_iteration=1
max_feature_idx=0
objective=binary sigmoid:1
feature_names=x0

Tree=0
num_leaves=2
num_cat=1
split_feature=0
threshold=0
decision_type=1
left_child=-1
right_child=-2
leaf_value=0.0 0.0
is_linear=0
shrinkage=1

end of trees
|} in
  Alcotest.check_raises "categorical → Invalid_argument"
    (Invalid_argument "Gbt_model: categorical splits not supported")
    (fun () -> ignore (Gbt.Gbt_model.of_text bad))

let test_rejects_linear_tree () =
  let bad = {|tree
version=v3
num_class=1
num_tree_per_iteration=1
max_feature_idx=0
objective=binary sigmoid:1
feature_names=x0

Tree=0
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.1 0.1
is_linear=1
shrinkage=1

end of trees
|} in
  Alcotest.check_raises "linear tree → Invalid_argument"
    (Invalid_argument "Gbt_model: linear tree leaves not supported")
    (fun () -> ignore (Gbt.Gbt_model.of_text bad))

(* Multiclass test: 3 classes, 2 trees per iteration (= 6 trees total
   over 2 iterations), single-feature stumps. *)
let sample_multiclass = {|tree
version=v3
num_class=3
num_tree_per_iteration=3
label_index=0
max_feature_idx=0
objective=multiclass num_class:3
feature_names=x0
feature_infos=[-1:1]
tree_sizes=50 50 50 50 50 50

Tree=0
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=1.0 -1.0
is_linear=0
shrinkage=1


Tree=1
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.5 0.5
is_linear=0
shrinkage=1


Tree=2
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.5 0.5
is_linear=0
shrinkage=1


Tree=3
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=0.2 -0.2
is_linear=0
shrinkage=1


Tree=4
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.1 0.1
is_linear=0
shrinkage=1


Tree=5
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-0.1 0.1
is_linear=0
shrinkage=1


end of trees
|}

let test_multiclass_parses () =
  let m = Gbt.Gbt_model.of_text sample_multiclass in
  Alcotest.(check int) "num_trees" 6 (Array.length m.trees);
  Alcotest.(check bool) "objective is Multiclass 3" true
    (m.objective = Multiclass 3)

let test_multiclass_softmax () =
  (* f0=0.0 ≤ 0.5 so every tree picks its left leaf.
     Trees interleave by class (0,1,2,0,1,2). Raw per class:
       c0 = 1.0 + 0.2 = 1.2
       c1 = -0.5 + -0.1 = -0.6
       c2 = -0.5 + -0.1 = -0.6
     Softmax probabilities must sum to 1, argmax = class 0. *)
  let m = Gbt.Gbt_model.of_text sample_multiclass in
  let raw = Gbt.Gbt_model.raw_score m ~features:[| 0.0 |] in
  Alcotest.(check int) "3 classes" 3 (Array.length raw);
  Alcotest.(check (float 1e-6)) "raw[0]"  1.2 raw.(0);
  Alcotest.(check (float 1e-6)) "raw[1]" (-0.6) raw.(1);
  Alcotest.(check (float 1e-6)) "raw[2]" (-0.6) raw.(2);
  let probs = Gbt.Gbt_model.predict_class_probs m ~features:[| 0.0 |] in
  Alcotest.(check (float 1e-6)) "probs sum = 1" 1.0
    (Array.fold_left (+.) 0.0 probs);
  Alcotest.(check bool) "argmax = 0" true
    (probs.(0) > probs.(1) && probs.(0) > probs.(2))

let tests = [
  "parses header",               `Quick, test_parses_header;
  "binary predict basic",        `Quick, test_binary_predict_basic;
  "binary predict left branch",  `Quick, test_binary_predict_left_branch;
  "binary predict right branch", `Quick, test_binary_predict_right_branch;
  "NaN uses default_left",       `Quick, test_nan_uses_default_left;
  "predict_class_probs binary",  `Quick, test_predict_class_probs_binary;
  "raw_score shape",             `Quick, test_raw_score_shape;
  "rejects categorical split",   `Quick, test_rejects_categorical_split;
  "rejects linear tree",         `Quick, test_rejects_linear_tree;
  "multiclass parses",           `Quick, test_multiclass_parses;
  "multiclass softmax",          `Quick, test_multiclass_softmax;
]

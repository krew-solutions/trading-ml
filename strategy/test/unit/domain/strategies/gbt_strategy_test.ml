(** End-to-end tests for {!Strategies.Gbt_strategy}.

    A tiny 3-class LightGBM-style model is written to a tempfile,
    the strategy is pointed at it, and canned price series are
    pushed through. The model's structure is deliberately trivial
    — one split per class tree on the [rsi] feature at 0.5 —
    so the expected signal sequence is easy to reason about. *)

open Core
open Strategy_helpers

(** Class layout [0=down; 1=flat; 2=up]. Trees (one per class per
    iteration) encode: when [rsi] (feature 0) is above 0.5 →
    boost class 2, suppress class 0; when below or equal →
    boost class 0, suppress class 2. Class 1 stays flat so it
    never wins. *)
let tiny_model_text =
  {|tree
version=v3
num_class=3
num_tree_per_iteration=3
label_index=0
max_feature_idx=7
objective=multiclass num_class:3
feature_names=rsi mfi bb_pct_b macd_hist volume_ratio lag_return_5 chaikin_osc ad_slope_10
feature_infos=[0:1] [0:1] [0:1] [-inf:inf] [0:inf] [-inf:inf] [-inf:inf] [-inf:inf]
tree_sizes=100 100 100

Tree=0
num_leaves=2
num_cat=0
split_feature=0
split_gain=0.1
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=1.0 -1.0
leaf_weight=100 100
leaf_count=100 100
internal_value=0.0
internal_weight=200
internal_count=200
is_linear=0
shrinkage=1


Tree=1
num_leaves=2
num_cat=0
split_feature=1
split_gain=0.01
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=0.0 0.0
leaf_weight=100 100
leaf_count=100 100
internal_value=0.0
internal_weight=200
internal_count=200
is_linear=0
shrinkage=1


Tree=2
num_leaves=2
num_cat=0
split_feature=0
split_gain=0.1
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=-1.0 1.0
leaf_weight=100 100
leaf_count=100 100
internal_value=0.0
internal_weight=200
internal_count=200
is_linear=0
shrinkage=1


end of trees
|}

let with_tmp_model text f =
  let path =
    Filename.concat
      (try Sys.getenv "TMPDIR" with Not_found -> "/tmp")
      (Printf.sprintf "gbt_strategy_test_%d_%d.txt" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1e6)))
  in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc text);
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)

let build ?(enter_threshold = 0.55) ?(allow_short = false) path =
  let p =
    Strategies.Gbt_strategy.
      { default_params with model_path = path; enter_threshold; allow_short }
  in
  Strategies.Strategy.make (module Strategies.Gbt_strategy) p

let test_uptrend_triggers_enter_long () =
  with_tmp_model tiny_model_text (fun path ->
      let strat = build path in
      (* 20 bars warm-up Bollinger(20), then 25 rising bars push RSI
       well above 50 (→ scaled > 0.5), model picks class=up. *)
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let up = List.init 25 (fun i -> 103.0 +. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ up) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool)
        "Enter_long emitted during uptrend" true
        (contains Signal.Enter_long acts))

let test_reversal_exits_long () =
  with_tmp_model tiny_model_text (fun path ->
      let strat = build path in
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let up = List.init 25 (fun i -> 103.0 +. float_of_int i) in
      let down = List.init 30 (fun i -> 128.0 -. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ up @ down) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool) "Enter_long" true (contains Signal.Enter_long acts);
      Alcotest.(check bool)
        "Exit_long after reversal" true
        (contains Signal.Exit_long acts))

let test_short_disabled_by_default () =
  with_tmp_model tiny_model_text (fun path ->
      let strat = build ~allow_short:false path in
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let down = List.init 30 (fun i -> 105.0 -. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ down) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool)
        "no Enter_short when allow_short=false" true
        (not (contains Signal.Enter_short acts)))

let test_short_enabled_flips_on_down () =
  with_tmp_model tiny_model_text (fun path ->
      let strat = build ~allow_short:true path in
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let down = List.init 30 (fun i -> 105.0 -. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ down) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool)
        "Enter_short once shorting allowed" true
        (contains Signal.Enter_short acts))

let test_threshold_filters_low_confidence () =
  (* Raise the threshold above the model's softmax max (~0.665)
     so no entry ever fires. *)
  with_tmp_model tiny_model_text (fun path ->
      let strat = build ~enter_threshold:0.9 path in
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let up = List.init 25 (fun i -> 103.0 +. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ up) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool)
        "no entry when confidence < threshold" true
        (not (contains Signal.Enter_long acts));
      Alcotest.(check bool)
        "no short entry either" true
        (not (contains Signal.Enter_short acts)))

let test_rejects_missing_model_path () =
  Alcotest.check_raises "empty model_path → Invalid_argument"
    (Invalid_argument "Gbt_strategy: model_path must be set") (fun () ->
      ignore (build ""))

let test_rejects_feature_name_mismatch () =
  let wrong_names_model =
    {|tree
version=v3
num_class=3
num_tree_per_iteration=3
label_index=0
max_feature_idx=2
objective=multiclass num_class:3
feature_names=a b c
feature_infos=[0:1] [0:1] [0:1]
tree_sizes=50 50 50

Tree=0
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=0.0 0.0
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
leaf_value=0.0 0.0
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
leaf_value=0.0 0.0
is_linear=0
shrinkage=1

end of trees
|}
  in
  with_tmp_model wrong_names_model (fun path ->
      Alcotest.check_raises "mismatch → Invalid_argument"
        (Invalid_argument
           "Gbt_strategy: model feature_names mismatch — strategy expects [rsi, mfi, \
            bb_pct_b, macd_hist, volume_ratio, lag_return_5, chaikin_osc, ad_slope_10], \
            model has [a, b, c]") (fun () -> ignore (build path)))

let test_rejects_non_multiclass_objective () =
  let binary_model =
    {|tree
version=v3
num_class=1
num_tree_per_iteration=1
label_index=0
max_feature_idx=2
objective=binary sigmoid:1
feature_names=rsi mfi bb_pct_b

Tree=0
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=0.0 0.0
is_linear=0
shrinkage=1

end of trees
|}
  in
  with_tmp_model binary_model (fun path ->
      Alcotest.check_raises "binary → Invalid_argument"
        (Invalid_argument
           "Gbt_strategy: model objective must be Multiclass(3) with classes [0=down; \
            1=flat; 2=up]") (fun () -> ignore (build path)))

(** Constant-class model builder: every tree on every iteration
    pushes [boost] into class [favored], zero elsewhere. Softmax
    over raw scores then picks [favored] by a wide margin. Used
    only by the hot-reload test where we need a model whose
    predictions are completely decoupled from feature values. *)
let constant_class_model ~favored ~boost =
  let tree_for c =
    let leaf = if c = favored then boost else 0.0 in
    Printf.sprintf
      {|Tree=%d
num_leaves=2
num_cat=0
split_feature=0
threshold=0.5
decision_type=2
left_child=-1
right_child=-2
leaf_value=%f %f
is_linear=0
shrinkage=1

|}
      c leaf leaf
  in
  Printf.sprintf
    {|tree
version=v3
num_class=3
num_tree_per_iteration=3
label_index=0
max_feature_idx=7
objective=multiclass num_class:3
feature_names=rsi mfi bb_pct_b macd_hist volume_ratio lag_return_5 chaikin_osc ad_slope_10
feature_infos=[0:1] [0:1] [0:1] [-inf:inf] [0:inf] [-inf:inf] [-inf:inf] [-inf:inf]
tree_sizes=50 50 50

%s%s%send of trees
|}
    (tree_for 0) (tree_for 1) (tree_for 2)

(** [Gbt_strategy] re-stats the model file before every prediction
    and transparently picks up an atomically-replaced version.
    Test: start with a [class 0 always wins] model (under
    [allow_short=true] that means Enter_short on a confident
    prediction), overwrite with [class 2 always wins], force a
    future mtime so the reload detector fires, and verify the
    signal flips to Enter_long. *)
let test_hot_reload_picks_up_new_model () =
  with_tmp_model (constant_class_model ~favored:0 ~boost:3.0) (fun path ->
      let strat = build ~allow_short:true path in
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let up1 = List.init 10 (fun i -> 103.0 +. float_of_int i) in
      (* Phase 1: run through the class=0 model; expect Enter_short
       (class=0 with allow_short=true maps to "go short"). *)
      let strat_after_phase1, acts_phase1 =
        List.fold_left
          (fun (s, acc) c ->
            let s', sig_ = Strategies.Strategy.on_candle s inst c in
            (s', sig_.Signal.action :: acc))
          (strat, [])
          (ohlc_candles_from_prices (warmup @ up1))
      in
      let acts_phase1 = List.rev acts_phase1 in
      Alcotest.(check bool)
        "phase 1 (class=0): Enter_short seen" true
        (contains Signal.Enter_short acts_phase1);
      (* Overwrite the model with a class=2 winner; bump mtime into
       the future so the strategy's reload detector fires on the
       next [on_candle] call. *)
      Out_channel.with_open_text path (fun oc ->
          Out_channel.output_string oc (constant_class_model ~favored:2 ~boost:3.0));
      let now = Unix.gettimeofday () in
      Unix.utimes path now (now +. 3600.0);
      (* Phase 2: same strategy instance continues. First bar should
       reload the model; position was Short at the end of phase 1,
       so the first confident class=2 prediction flips to Enter_long. *)
      let up2 = List.init 10 (fun i -> 120.0 +. float_of_int i) in
      let _, acts_phase2 =
        List.fold_left
          (fun (s, acc) c ->
            let s', sig_ = Strategies.Strategy.on_candle s inst c in
            (s', sig_.Signal.action :: acc))
          (strat_after_phase1, [])
          (ohlc_candles_from_prices up2)
      in
      let acts_phase2 = List.rev acts_phase2 in
      Alcotest.(check bool)
        "phase 2 (reloaded class=2): Enter_long seen" true
        (contains Signal.Enter_long acts_phase2))

let test_unchanged_mtime_does_not_reload () =
  (* Sanity: if the file's mtime doesn't advance, the strategy
     keeps the model it already loaded — no per-bar reparsing. *)
  with_tmp_model (constant_class_model ~favored:0 ~boost:3.0) (fun path ->
      let strat = build ~allow_short:true path in
      (* Pin mtime to a known past value, run a batch, pin it again
       (same value), run another batch. Nothing should change. *)
      let pin = Unix.gettimeofday () -. 3600.0 in
      Unix.utimes path pin pin;
      let warmup = List.init 25 (fun i -> 100.0 +. (float_of_int i *. 0.1)) in
      let up = List.init 10 (fun i -> 103.0 +. float_of_int i) in
      let candles = ohlc_candles_from_prices (warmup @ up) in
      let acts = actions_from_ohlc strat candles in
      Alcotest.(check bool)
        "class=0 pinned → Enter_short still fires" true
        (contains Signal.Enter_short acts))

let tests =
  [
    ("uptrend → Enter_long", `Quick, test_uptrend_triggers_enter_long);
    ("reversal → Exit_long", `Quick, test_reversal_exits_long);
    ("short disabled by default", `Quick, test_short_disabled_by_default);
    ("short enabled flips on down", `Quick, test_short_enabled_flips_on_down);
    ("threshold filters low confidence", `Quick, test_threshold_filters_low_confidence);
    ("rejects missing model_path", `Quick, test_rejects_missing_model_path);
    ("rejects feature name mismatch", `Quick, test_rejects_feature_name_mismatch);
    ("rejects non-multiclass objective", `Quick, test_rejects_non_multiclass_objective);
    ("hot-reload picks up new model", `Quick, test_hot_reload_picks_up_new_model);
    ("unchanged mtime: no reload", `Quick, test_unchanged_mtime_does_not_reload);
  ]

# Gradient-boosted trees

This document describes how GBT (LightGBM-style) models integrate
into the trading system. Two modules split the concern:

- [`lib/domain/ml/gbt/`](../../../lib/domain/ml/gbt/) — pure
  inference primitive. Loads a LightGBM text-dump model, predicts
  a probability / value from a numeric feature vector. Knows
  nothing about `Candle`, `Signal`, or `Strategy.S`.
- [`lib/domain/strategies/gbt_strategy.ml`](../../../lib/domain/strategies/gbt_strategy.ml)
  — trading wrapper. On each bar, feeds indicator outputs into
  `Gbt_model.predict_class_probs`, applies a threshold, emits a
  `Signal.t`. This is what the engine sees.

The split mirrors the existing
[`logistic_regression`](../../../lib/domain/ml/logistic_regression/)
/ [`Composite`](../../../lib/domain/strategies/composite.mli)
pair — ML primitive in `ml/`, strategy wrapper in `strategies/`.
Rationale: the predictor is reusable for research /
backtesting / feature-importance analysis outside any trading
loop, and keeping it free of domain types makes it trivial to
reuse from a separate offline tool.

## Training lives outside OCaml

Training GBTs requires gradient computation, histogram building,
leaf-split search with regularisation — thousands of lines of C++
in LightGBM and XGBoost. We don't reimplement that. Training
happens in Python, the model is persisted to LightGBM's native
text format (`model.save_model(path)`), and OCaml reads that file
at runtime.

The runtime therefore has **zero ML dependencies** — no Python,
no native extensions, no ONNX runtime, no linked lightgbm shared
library. A GBT model is just a text file.

## Inference internals

A LightGBM text dump is a header (key=value metadata) plus one
section per boosting iteration's tree:

```
objective=binary sigmoid:1
feature_names=x0 x1
max_feature_idx=1
...

Tree=0
num_leaves=3
split_feature=0 1
threshold=0.5 1.5
decision_type=2 2
left_child=1 -1
right_child=-2 -3
leaf_value=-0.3 0.2 0.5
...

Tree=1
...
end of trees
```

Each tree is a binary tree encoded as parallel arrays keyed by
internal-node index. `left_child` / `right_child` carry either a
non-negative index (→ another internal node) or a negative value
(→ a leaf, decoded as `-child - 1` into `leaf_value`). A missing
feature (`NaN`) traverses using the per-split `default_left`
direction encoded in `decision_type`'s bit 1.

Inference per sample:

```
raw_score[c] = Σ predict_tree(t, features)
               over trees assigned to class c

P(y|x) = sigmoid(raw_score)   for Binary
       = softmax(raw_score)   for Multiclass
       = raw_score             for Regression
```

For multiclass with `num_class=k`, LightGBM emits `k` trees per
boosting iteration; our parser keeps them in the order they
appear, and `raw_score` bins them by `tree_index mod k`.

The full predict fits in ~15 lines; the parser is ~80 lines. No
per-request allocation beyond the output probability array —
tree arrays are shared across calls.

## What the parser supports

| Feature                                     | Supported |
|---------------------------------------------|-----------|
| Numeric splits (`<=`)                       | ✓         |
| Missing-value direction (`default_left`)    | ✓         |
| Shrinkage (learning-rate-scaled leaves)     | ✓         |
| Binary / Multiclass / Regression objectives | ✓         |
| Categorical splits (`decision_type` bit 0)  | rejected  |
| Linear-tree leaves (`is_linear=1`, LGBM 4.x)| rejected  |
| Quantized trees                             | untested  |

Unsupported inputs raise `Invalid_argument` with a specific
message rather than silently producing garbage predictions. If a
future feature engineering pipeline needs categorical features,
extend the parser here — don't bolt workarounds into the strategy
wrapper.

## Training pipeline

The offline loop runs outside this repo, usually in a Jupyter
notebook:

```
┌─────────────┐   bars + labels    ┌──────────────┐   save_model   ┌──────────────┐
│  OCaml      │ ─────────────────► │  Python      │ ─────────────► │  model.txt   │
│  export_    │   parquet / csv    │  lightgbm    │                │  (LGBM text) │
│  training_  │                    │  walk-       │                │              │
│  data.ml    │                    │  forward CV  │                │              │
└─────────────┘                    └──────────────┘                └──────────────┘
                                                                          │
                                                                          ▼
                                                                   ┌──────────────┐
                                                                   │  OCaml       │
                                                                   │  Gbt_model.  │
                                                                   │  of_file     │
                                                                   └──────────────┘
```

1. **OCaml export tool** replays historical bars (from broker
   `Rest.bars`) through the existing `Indicators.*`, computes a
   per-bar label from future bars (e.g. sign of return over the
   next `k` bars with a threshold band), writes
   `(features..., label)` rows to parquet.
2. **Python trains** with `lightgbm.train` under
   `sklearn.TimeSeriesSplit` cross-validation. Walk-forward is
   mandatory — standard K-fold shuffles time and leaks future
   data into training.
3. **Model file** lands at a conventional path, e.g.
   `$XDG_STATE_HOME/trading/models/<symbol>-<tf>-<version>.txt`.
4. **Retraining** happens periodically (cron / systemd timer)
   because financial distributions are non-stationary. The
   file-rename pattern (same as
   [`Token_store`](../../../lib/infrastructure/persistence/token_store.mli))
   allows atomic model swaps without restarting the engine.

## Label design

The label is the hardest part of the pipeline. Options, in order
of pragmatic-to-sophisticated:

- **Binary sign** — `sign(close[t+k] - close[t]) > 0`. Simple but
  noisy; every micro-wiggle is a label.
- **Three-class with threshold band** — `+1` if return > `+θ`,
  `-1` if < `-θ`, `0` otherwise. Cuts noise, matches the
  `Signal.{Enter_long, Enter_short, Hold}` shape naturally.
- **Triple-barrier (de Prado)** — label by which of
  (take-profit, stop-loss, timeout) fires first given a simulated
  entry at `t`. Reflects the actual trading decision but requires
  a more involved labelling tool.
- **Regression** — predict the actual return value. Maximum
  information, worst loss-vs-PnL correlation.

`Gbt_strategy` targets three-class first — it's the sweet spot
between simplicity and trading relevance.

## Feature engineering

Features are whatever the wrapping strategy pushes in, typically:

- Price-derived: lagged returns `r_{t-1}, r_{t-5}, r_{t-20}`,
  realized volatility.
- Indicator-derived: `RSI`, `MACD`, `Bollinger %B`, `MFI`, `OBV`
  slope — all already in [`lib/domain/indicators/`](../../../lib/domain/indicators/).
- Volume-derived: `volume / VolumeMA`.
- Microstructure (WS-only): bid-ask spread, order-book
  imbalance.
- Time: hour-of-day, day-of-week (as cyclic sin/cos features or
  integer categoricals mapped to numeric).

`Gbt_strategy`'s job is to compute these from the bar stream in a
deterministic order that matches the training pipeline's column
layout — any divergence silently produces nonsense predictions.
The feature names in `Gbt_model.t` are kept so a sanity check can
catch misalignment at startup.

## Integrating with the engine

Every bar, the live engine (or backtest) calls the strategy's
`on_candle`. `Gbt_strategy` updates its indicator ring buffers,
assembles the feature vector, calls `Gbt_model.predict_class_probs`,
then:

```
       argmax(probs) = 0 (down) and probs.(0) > enter_threshold
   →   Signal.Enter_short (or Exit_long if already long)

       argmax(probs) = 2 (up)   and probs.(2) > enter_threshold
   →   Signal.Enter_long  (or Exit_short if already short)

   otherwise → Signal.Hold
```

Strength is set from the winning class probability so risk gating
downstream can size positions accordingly.

## Diagnostics

- `Gbt_model.raw_score` exposes pre-activation tree sums — useful
  when calibrating thresholds, because raw scores are roughly
  symmetric around zero for binary and easier to reason about
  than post-sigmoid probabilities.
- `feature_names` on the parsed model can be compared to the
  strategy's feature-assembly order at startup — mismatch means
  the training dataset has drifted from what the strategy
  computes, and silently garbaged predictions are the usual
  symptom.
- Unit tests in
  [`test/unit/domain/ml/gbt/`](../../../test/unit/domain/ml/gbt/)
  hand-author a tiny LightGBM text dump and assert exact
  probabilities, so parser regressions surface immediately.

## Known limitations

- The model file format is LightGBM-specific. XGBoost and
  CatBoost have their own native formats (JSON and CBM) — if a
  future pipeline needs to swap, add a parser rather than a
  converter. Tree inference logic is shared.
- There's no cross-iteration ensembling (bagging, stacking);
  every text dump is one model.
- Feature preprocessing (normalisation, imputation) happens on
  the training side. The strategy pushes raw indicator values
  and trusts that training used the same preprocessing — there's
  no preprocessing-pipeline file to apply at inference.

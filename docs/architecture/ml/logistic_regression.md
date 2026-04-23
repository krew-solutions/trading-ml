# Logistic regression

A minimal online logistic classifier used as the gating function
inside [`Composite`](../../../lib/domain/strategies/composite.mli)'s
`Learned` policy. Predates the GBT pipeline and serves a different
architectural role — not "replace heuristic strategies with an ML
model", but "let a lightweight classifier decide which of the
existing heuristic strategies' signals to trust right now".

See also [gbt.md](gbt.md) for the tree-ensemble counterpart and
how the two approaches differ in intent.

## Module layout

Three focused files under [`lib/domain/ml/logistic_regression/`](../../../lib/domain/ml/logistic_regression/):

- [`logistic.ml`](../../../lib/domain/ml/logistic_regression/logistic.ml)
  — the math: sigmoid, `predict`, SGD step, L2-regularised
  `train`. ~70 lines, zero external deps.
- [`features.ml`](../../../lib/domain/ml/logistic_regression/features.ml)
  — feature-vector builder from child signals + market context.
  Produces `2·n_children + 2` scalars per bar.
- [`trainer.ml`](../../../lib/domain/ml/logistic_regression/trainer.ml)
  — offline training loop: replays child strategies over a
  historical candle series, derives binary labels from forward
  returns, trains a `Logistic.t` with a 70/30 train/val split.

## The model itself

Single-layer linear classifier with a sigmoid head:

```
P(y=1 | x) = sigmoid( bias + Σᵢ wᵢ · xᵢ )
```

Weights are a plain `float array` of length `1 + n_features`
(position 0 is the bias term). Training is stochastic gradient
descent with optional L2 weight decay — one gradient step per
sample, repeated across `epochs` passes:

```
∂loss/∂w_i  =  (pred − target) · x_i + λ · w_i     # logistic + L2
w_i         ←  w_i − lr · ∂loss/∂w_i
```

Defaults: `lr = 0.01`, `l2 = 1e-4`, `epochs = 10`. Tunable
per-call. The `sigmoid` clamps to `[0, 1]` outside `|z| > 15` to
avoid `exp` overflow — numerically cosmetic, predictions at
those extremes are already saturated.

Weights round-trip through `export_weights` / `of_weights`, so a
trained model becomes a plain `float array` that embeds cleanly
into a config-file, test fixture, or `Composite.Learned` params.

## Feature vector

`Features.extract` maps `(signals, candle, recent_closes, recent_volumes)`
to a flat float array, ordered so index positions are stable
regardless of child-strategy identity:

```
┌──────────────────────────── per-child, interleaved ───────────────────────────┐
  signal₁, strength₁, signal₂, strength₂, …, signalₙ, strengthₙ,
└──────────────────────────────── market context ───────────────────────────────┘
  volatility, volume_ratio
```

- `signalᵢ` ∈ {+1, 0, −1}: `Enter_long → +1`, `Hold → 0`, any
  exit or short → −1. Discrete encoding; the classifier learns
  its own weights without any assumed magnitude.
- `strengthᵢ` — `Signal.strength`, already in `[0, 1]`, passed
  through unchanged.
- `volatility` — coefficient of variation of `recent_closes`
  (std / mean); proxy for "is the market jittery right now?".
- `volume_ratio` — current bar volume / mean of `recent_volumes`;
  proxy for "is this bar unusually active?".

The two market-context features are load-bearing. The point of
`Learned` is to learn conditional trust: "SMA crossover works in
low-vol regimes but not high-vol ones" is exactly the kind of
rule a dumb `Majority` or rolling-Sharpe `Adaptive` policy can't
express. A flat trust-weighting would underperform in the
regime switch; a classifier that sees volatility as a feature
can adapt.

Feature count formula: `n_features(~n_children) = 2·n_children + 2`.
Wired consistently so `Trainer.train` and runtime `Features.extract`
agree on dimension; a mismatch would silently cause the sigmoid
to read garbage weights at position `2i+1`.

## Training loop

`Trainer.train ~children ~candles` does offline walk-forward:

1. **Replay children** over the candle stream. Every child
   strategy is stepped once per bar in lockstep; signals are
   collected into `all_signals.(i)`.
2. **Label derivation**. At bar `i` with at least one non-Hold
   child signal: target = `1.0` if
   `close[i + lookahead] > close[i]`, else `0.0`. Lookahead
   defaults to 5 bars.
3. **Skip no-decision bars**. If every child held, there's
   nothing to learn from that bar — it's dropped, not labelled
   zero.
4. **Split 70/30**. First seven-tenths of the collected dataset
   becomes training, the last three-tenths is held out for
   validation-loss measurement.
5. **SGD over training split** for `epochs` passes.
6. **Report** train loss, val loss, sample counts, and the
   exported weight vector.

Walk-forward discipline is enforced by the ordering: the label
at bar `i` reads `close[i + lookahead]`, which is strictly in
the past relative to the end of the candle history. No
future-to-past leakage is possible because children are
replayed one bar at a time and targets compute forward within
the closed training window.

## Where it plugs into the strategy layer

```
                        ┌─────────────────────────────────┐
   ┌──────────────┐     │                                 │
   │ Child strats │──── signals ──┐                       │
   │ (SMA, RSI,  │                │                       │
   │  MACD, BB,   │                ▼                       │
   │   …)        │          ┌─────────────┐               │
   └──────────────┘          │ Features.   │               │
                              │ extract     │               │
   bar / market context ─────▶│             │──── features ▶│ Composite.Learned
                              └─────────────┘               │     │
                                                            │     ▼
                                                            │   Logistic.predict
                                                            │     │
                                                            │     ▼
                                                            │  P(profitable)
                                                            │     │
                                                            │     ▼
                                                            │  vs threshold?
                                                            │  → Enter_long / Hold
                                                            │
                                                            └─────────────────────┘
```

`Composite` with `policy = Learned { predict; threshold }` wires
a closure that combines `Features.extract` with the learned
weights. The composite itself has no ML dependency — it takes
`predict : Signal.t list -> Candle.t -> float list -> float list -> float`
at construction time, and the predictor is injected from
outside. That keeps the strategies layer free of logistic /
gradient-descent concepts and localises the "thinking" to this
module.

## Why logistic, why here

Logistic regression is the simplest thing in supervised ML that
learns **conditional combinations**:

- It can express "SMA matters when volatility is low" because
  the weighted sum lets features interact multiplicatively
  through cross-products (if you add them; we don't, so strictly
  linear — see below).
- Training is fast on small sample sizes (hundreds to thousands
  of bars), where neural nets would overfit and tree ensembles
  bring more machinery than payoff.
- The learned weights are human-readable: you can inspect which
  child strategy the model trusted, and under which regime.

What it **doesn't** handle (limitations to keep in mind):

- Purely linear in its inputs. Can't learn "SMA × volatility"
  as an interaction term without feature engineering (add the
  product explicitly as a feature).
- Cannot express "flip my prediction between regimes" cleanly;
  that's what non-linear models (GBT, neural nets) do naturally.
- L2 is the only regulariser available; no early stopping, no
  dropout, no ensembling. Small dataset discipline matters.

For problems where a bigger model is justified, use the GBT
pipeline (`Gbt_strategy` + `Gbt_model`) — it handles
non-linearities, exhaustiveness warnings over feature value
ranges, and a richer training ecosystem (LightGBM). Logistic
stays here for its role as a **fast, transparent gate for
pre-existing heuristic strategies**, not as an alpha generator
in its own right.

## Runtime shape

All computation is pure `float` array arithmetic:

- `Logistic.predict` — one dot product + one sigmoid. Microseconds.
- `Features.extract` — array writes + two mean/std folds over
  recent-history lists. Microseconds.
- `Trainer.train` — SGD loop. Seconds on tens of thousands of
  bars; runs once offline.

No dependencies beyond stdlib. No file IO (weights are
marshalled as `float array` into config-land by callers).
Unlike `Gbt_model` — which loads models from disk and watches
mtime — logistic weights are small (e.g. 10 scalars for 4
children), so they live in config or test fixtures, not
separate files.

## Testing

Three test files mirror the three modules:

- [`test/unit/domain/ml/logistic_test.ml`](../../../test/unit/domain/ml/logistic_test.ml)
  — sigmoid boundary behaviour, SGD converges on a toy linearly
  separable set, weight export/import round-trip.
- [`test/unit/domain/ml/features_test.ml`](../../../test/unit/domain/ml/features_test.ml)
  — feature ordering is stable; market-context features land at
  the right indices.
- [`test/unit/domain/ml/trainer_test.ml`](../../../test/unit/domain/ml/trainer_test.ml)
  — walk-forward label discipline (no future leakage); empty
  dataset case; train/val split shape.

Plus [`learned_policy_test.ml`](../../../test/unit/domain/strategies/)
under strategies exercises the end-to-end `Composite.Learned`
integration.

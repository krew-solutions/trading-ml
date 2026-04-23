# GBT training tools

Python scripts for training and evaluating the LightGBM models
consumed by `Strategies.Gbt_strategy`. The OCaml runtime has
zero ML dependencies — training is strictly offline, and these
scripts are the supported offline path.

See also:

- [`docs/howto/ml/gbt.md`](../../docs/howto/ml/gbt.md) — full
  pipeline from broker → CSV → model → live strategy.
- [`docs/architecture/ml/gbt.md`](../../docs/architecture/ml/gbt.md)
  — design and inference internals.

## Setup

```bash
python -m venv ~/.venvs/trading-ml
source ~/.venvs/trading-ml/bin/activate
pip install -r requirements.txt
```

One-time setup; activate the venv whenever running these scripts.

## Scripts

### `train.py` — train a model

```bash
python train.py \
  --input  /tmp/sber_h1.csv \
  --output ~/.local/state/trading/models/sber_h1_v1.txt
```

Performs walk-forward cross-validation (`TimeSeriesSplit`)
across `--n-splits` folds, prints per-fold accuracy and
best-iteration numbers, then retrains on the full history (or
`--final-fraction` tail) using the median best-iter from CV as
the final `num_boost_round`.

Tunable without editing code:

| Flag                   | Purpose                                       |
|------------------------|-----------------------------------------------|
| `--n-splits N`         | Walk-forward CV folds (default 5)             |
| `--num-boost-round N`  | Max trees per fold (default 500)              |
| `--early-stopping N`   | No-improvement patience (default 30)          |
| `--learning-rate F`    | Step size shrinkage (default 0.03)            |
| `--num-leaves N`       | Leaves per tree cap (default 31)              |
| `--max-depth N`        | Tree depth cap (default 5)                    |
| `--min-data-in-leaf N` | Regularisation via min-leaf-count (default 200) |
| `--seed N`             | Reproducibility (default 42)                  |
| `--params-json FILE`   | Deep override: any LightGBM param as JSON     |
| `--final-fraction F`   | Tail fraction for final model (default 1.0)   |

Typical output:

```
Input:    /tmp/sber_h1.csv  (8616 rows)
Features: ['rsi', 'mfi', 'bb_pct_b']
Labels:   0=2890 (33.5%), 1=2802 (32.5%), 2=2924 (33.9%)

=== Walk-forward CV (5 splits) ===
  fold 1/5: train=1436  test=1436  acc=0.4021  best_iter=38
  fold 2/5: train=2872  test=1436  acc=0.4156  best_iter=47
  fold 3/5: train=4308  test=1436  acc=0.4089  best_iter=52
  fold 4/5: train=5744  test=1436  acc=0.4123  best_iter=44
  fold 5/5: train=7180  test=1436  acc=0.4201  best_iter=51

  mean acc = 0.4118 (±0.0066)
  baseline = 0.3333 (random 3-class)
  lift     = +7.85 pp
  best_iter by fold = [38, 47, 52, 44, 51] (median 47)

Final model: rows [0:8616] (8616 rows) × 50 rounds
Saved → /tmp/sber_h1_v1.txt  (45,312 bytes, 150 trees)

=== Feature importance (gain) ===
  rsi          gain=   1204.3  (42.8%)
  bb_pct_b     gain=    987.6  (35.1%)
  mfi          gain=    621.8  (22.1%)
```

### `evaluate.py` — score an existing model

```bash
python evaluate.py \
  --model /tmp/sber_h1_v1.txt \
  --input /tmp/sber_h1_last_month.csv
```

Used for drift monitoring: export recent data, compare
accuracy / confusion matrix to the original training run. A
persistent drop is the signal to retrain.

Prints accuracy with lift over random baseline, a confusion
matrix (rows = actual, cols = predicted), per-class
precision/recall, and the first `--top-n` predictions for
spot-checking.

## Feature-column contract

Both scripts hard-code the expected CSV schema:

```python
EXPECTED_FEATURES = ["rsi", "mfi", "bb_pct_b"]
LABEL_COL = "label"
NUM_CLASSES = 3
```

These must match `Strategies.Gbt_strategy.feature_names` on the
OCaml side. If you add a feature:

1. Add the column writer in `bin/export_training_data.ml`
   (`compute_features` + the header row).
2. Extend `Strategies.Gbt_strategy.feature_names` and the
   feature-assembly code in `Gbt_strategy.on_candle`.
3. Append the name here in `EXPECTED_FEATURES`.

The OCaml side validates the model's `feature_names` header
against the strategy's array at `init` time and refuses
mismatches — that's the drift safety net.

## Exit codes

Both scripts exit `0` on success, non-zero on failure. Useful
in a cron wrapper:

```bash
set -euo pipefail
python train.py --input "$CSV" --output "$MODEL"
ln -sf "$MODEL" "$CURRENT"
```

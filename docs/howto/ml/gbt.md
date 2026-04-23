# How to train and deploy a GBT strategy

End-to-end walkthrough: pull historical bars from a broker, train
a LightGBM classifier offline, and run it as a live strategy
through the OCaml engine.

For the design background (why GBT, why split `ml/gbt/` from
`strategies/gbt_strategy/`, the text-dump inference internals) see
[architecture/ml/gbt.md](../../architecture/ml/gbt.md). This
document assumes you've read that and focuses on the mechanics.

## Prerequisites

- Broker credentials exported (either in the shell or persisted
  via `Token_store`). For BCS: `BCS_SECRET` and optionally
  `BCS_CLIENT_ID=trade-api-write`. For Finam: `FINAM_SECRET` and
  `FINAM_ACCOUNT_ID`.
- Python ≥ 3.11 with `lightgbm`, `pandas`, `scikit-learn`,
  `numpy`. Install in a venv:

  ```bash
  python -m venv ~/.venvs/trading-ml
  source ~/.venvs/trading-ml/bin/activate
  pip install lightgbm pandas scikit-learn numpy
  ```

- OCaml side built: `dune build`.

## Step 1 — Export the training dataset

The `export_training_data` binary pulls historical bars, replays
them through the same feature roster `Gbt_strategy` uses at
inference (RSI / MFI / Bollinger %B), labels each row from the
future bar's return, and writes CSV.

```bash
dune exec -- bin/export_training_data.exe -- \
  --broker bcs \
  --symbol SBER@MISX \
  --timeframe H1 \
  --from 2024-01-01 \
  --to 2026-04-20 \
  --horizon 5 \
  --threshold 0.005 \
  --output /tmp/sber_h1.csv
```

Options:

- `--broker`    — `finam` or `bcs`.
- `--symbol`    — qualified `TICKER@MIC` (optional `/BOARD`).
- `--timeframe` — `M1 | M5 | M15 | M30 | H1 | H4 | D1` (default `H1`).
- `--from` / `--to` — ISO date (`YYYY-MM-DD`) or full RFC 3339.
  Default window is the last 365 days.
- `--label-mode` — `threshold` (default) or `triple-barrier`.
- `--output`     — CSV path.

**Threshold mode** (default, simple):

- `--horizon`   — lookahead in bars for the label (default 5).
- `--threshold` — symmetric return band: `ret > +θ` → class `2`
  (up), `ret < -θ` → class `0` (down), otherwise `1` (flat).
  Default `0.005` (0.5%).

**Triple-barrier mode** (per de Prado, path-sensitive):

- `--tp-mult`  — take-profit barrier at `close + tp_mult × ATR(14)`;
  default `1.5`.
- `--sl-mult`  — stop-loss barrier at `close - sl_mult × ATR(14)`;
  default `1.0`.
- `--timeout`  — bars to walk forward; default `20`.

The labeler walks forward bar-by-bar; the first barrier to
trigger (TP hit → class 2, SL hit → class 0) wins. If neither
fires within `--timeout`, class 1 (flat). Bars whose `[low, high]`
range straddles both barriers in one shot (gap bars) get class 0
as a conservative tie-break.

The triple-barrier label is the one to use when your downstream
strategy will trade with actual TP/SL brackets — it matches
what your trade outcome actually will be, unlike the threshold
label which only looks at one future close.

The tool paginates through the broker's per-call cap (BCS
hard-limits at 1440 bars) and dedups on the chunk boundary. On
completion it prints:

```
Fetched 8640 bars from bcs (SBER@MISX)
Wrote 8616 rows to /tmp/sber_h1.csv (skipped 19 warmup, 5 tail bars w/o future)
```

The CSV has a header row:

```
ts,rsi,mfi,bb_pct_b,macd_hist,volume_ratio,lag_return_5,chaikin_osc,ad_slope_10,label
1704067200,0.485,0.472,0.312,0.124,1.05,0.002,-3412.1,0.015,1
1704070800,0.512,0.506,0.401,0.156,0.98,0.004,-2201.4,0.022,2
...
```

The leading `ts` column is the bar's unix-seconds timestamp — not
fed to the model during training, but handy for debugging
(joining predictions back to prices, slicing by calendar regime,
etc.). The training script drops it automatically.

## Step 2 — Train in Python

The training script lives at [`tools/gbt/train.py`](../../../tools/gbt/train.py)
— a CLI tool with walk-forward CV, early stopping, feature
importance, and configurable tree params. See
[`tools/gbt/README.md`](../../../tools/gbt/README.md) for the
full flag list.

```bash
source ~/.venvs/trading-ml/bin/activate
cd tools/gbt
python train.py \
  --input  /tmp/sber_h1.csv \
  --output ~/.local/state/trading/models/sber_h1_v1.txt
```

Expected output shape (actual numbers vary with market and
period):

```
Input:    /tmp/sber_h1.csv  (8616 rows)
Features: ['rsi', 'mfi', 'bb_pct_b', 'macd_hist', 'volume_ratio', 'lag_return_5', 'chaikin_osc', 'ad_slope_10']
Labels:   0=2890 (33.5%), 1=2802 (32.5%), 2=2924 (33.9%)

=== Walk-forward CV (5 splits) ===
  fold 1/5: train=1436  test=1436  acc=0.4021  best_iter=38
  ...
  fold 5/5: train=7180  test=1436  acc=0.4201  best_iter=51

  mean acc = 0.4118 (±0.0066)
  baseline = 0.3333 (random 3-class)
  lift     = +7.85 pp
  best_iter by fold = [38, 47, 52, 44, 51] (median 47)

Final model: rows [0:8616] (8616 rows) × 50 rounds
Saved → /.../sber_h1_v1.txt  (45,312 bytes, 150 trees)

=== Feature importance (gain) ===
  rsi            gain=   1204.3  (38.2%)
  bb_pct_b       gain=    987.6  (31.3%)
  macd_hist      gain=    412.1  (13.1%)
  mfi            gain=    305.7  ( 9.7%)
  volume_ratio   gain=    156.3  ( 5.0%)
  lag_return_5   gain=     84.9  ( 2.7%)
Meta  → /.../sber_h1_v1.meta.json
```

The sidecar `sber_h1_v1.meta.json` written next to the model
captures training-time context for audits: data provenance
(input CSV path, row count, label distribution), CV numbers
(per-fold accuracy, mean/std, baseline lift, best-iter median),
final model stats (trees, bytes), full LightGBM params, feature
importance, and Python/lightgbm versions. The file is read by
`evaluate.py` later to print the original CV baseline alongside
today's accuracy — so drift shows up as a single delta line.

**Reading the numbers**: a three-class task with roughly balanced
labels has random-baseline accuracy 1/3 ≈ 0.333. Anything
materially above that (say ≥ 0.38) is signal. If the mean drops
below 0.34 or fold-to-fold variance is very high, the model
isn't generalizing — revisit feature engineering, label
threshold, or admit the target isn't predictable at this
horizon. Feature-importance with one feature at 70%+ and others
at <5% is another smell — usually the model latched onto a
single proxy for the label and isn't combining signals.

### Monitoring a deployed model

[`tools/gbt/evaluate.py`](../../../tools/gbt/evaluate.py) scores
an existing model against a CSV — useful for drift detection:

```bash
# Export just the last month so we're scoring on recent-ish data.
dune exec -- bin/export_training_data.exe -- \
  --broker bcs --symbol SBER@MISX \
  --from 2026-03-20 --to 2026-04-20 \
  --output /tmp/sber_h1_recent.csv

python tools/gbt/evaluate.py \
  --model ~/.local/state/trading/models/sber_h1_v1.txt \
  --input /tmp/sber_h1_recent.csv
```

If accuracy on recent data drops below CV-baseline minus 2–3
percentage points and stays there across a couple of checks,
retrain.

## Step 3 — Inspect the model file

A quick sanity check on the saved text dump:

```bash
head -12 /tmp/sber_h1_v1.txt
```

Expected top:

```
tree
version=v4
num_class=3
num_tree_per_iteration=3
label_index=0
max_feature_idx=2
objective=multiclass num_class:3
feature_names=rsi mfi bb_pct_b
feature_infos=[...] [...] [...]
tree_sizes=...
```

Two things to confirm:

1. `feature_names=rsi mfi bb_pct_b` — the order must match
   `Strategies.Gbt_strategy.feature_names` exactly. If it doesn't,
   `Gbt_strategy.init` refuses to load the model with a pointed
   error; don't try to reorder the CSV columns to paper over a
   drift, fix it at source.
2. `objective=multiclass num_class:3` — a binary or regression
   dump will be rejected at load.

## Step 4 — Use the model

### Programmatic use

```ocaml
let strat =
  let open Strategies.Gbt_strategy in
  Strategies.Strategy.make (module Strategies.Gbt_strategy)
    { default_params with
      model_path = "/tmp/sber_h1_v1.txt";
      enter_threshold = 0.55;
      allow_short = false; }
```

Wire the result into a `Backtest.run` or a `Live_engine.start`
the same way any other strategy is wired.

### Via the Registry

`Gbt_strategy` is registered under the name `"GBT"` with params
(`model_path`, `enter_threshold`, `allow_short`, `rsi_period`,
`mfi_period`, `bb_period`, `bb_k`). Callers routing through the
registry pass `model_path` like any other param:

```ocaml
let params : (string * Strategies.Registry.param) list = [
  "model_path",      String "/tmp/sber_h1_v1.txt";
  "enter_threshold", Float 0.55;
] in
let strat = (Strategies.Registry.find "GBT" |> Option.get).build params
```

The UI strategy picker renders a param form beneath the
strategy dropdown — numeric fields for int/float, checkboxes for
bool, text inputs for string (like `model_path`). Default values
come from the registry spec; user edits are sent as-is in the
`/api/backtest` POST body:

```json
{
  "strategy": "GBT",
  "symbol": "SBER@MISX",
  "params": {
    "model_path": "/home/ivan/.local/state/trading/models/sber_h1_current.txt",
    "enter_threshold": 0.6,
    "allow_short": false
  }
}
```

## Retraining

Financial distributions drift — a model trained on 2024 quietly
decays through 2025. Rerun steps 1 and 2 periodically:

```bash
# weekly cron, example
0 3 * * MON ~/trading/bin/retrain.sh
```

where `retrain.sh` roughly is:

```bash
#!/bin/bash
set -euo pipefail

TODAY=$(date -u +%Y-%m-%d)
FROM=$(date -u -d '2 years ago' +%Y-%m-%d)
MODEL_DIR="$HOME/.local/state/trading/models"
REPO="$HOME/emacsway/apps/trading"
mkdir -p "$MODEL_DIR"

# 1. Export fresh dataset.
cd "$REPO"
dune exec -- bin/export_training_data.exe -- \
  --broker bcs --symbol SBER@MISX \
  --from "$FROM" --to "$TODAY" \
  --output "$MODEL_DIR/sber_h1_$TODAY.csv"

# 2. Train. Venv must already exist; see tools/gbt/README.md.
source ~/.venvs/trading-ml/bin/activate
python "$REPO/tools/gbt/train.py" \
  --input  "$MODEL_DIR/sber_h1_$TODAY.csv" \
  --output "$MODEL_DIR/sber_h1_$TODAY.txt"

# 3. Atomic swap — same rename pattern as Token_store.save.
ln -sf "$MODEL_DIR/sber_h1_$TODAY.txt" "$MODEL_DIR/sber_h1_current.txt"
```

`Gbt_strategy` watches the model file by mtime and transparently
reloads on change. The atomic rename pattern above (`ln -sf`
through a dated tmp target) causes a single mtime bump that the
strategy picks up before its next prediction — no engine restart
needed. A parse failure on the new file raises loudly rather
than falling back to the old model silently; supervision
decides whether to halt or roll back.

## Troubleshooting

### `Gbt_strategy: model feature_names mismatch`

The trained model's `feature_names` header doesn't match
`Strategies.Gbt_strategy.feature_names` exactly. Root cause is
almost always one of:

- The CSV's header row was edited by hand.
- `train_gbt.py` was passed `feature_name=` in a different order.
- Someone added a feature to `export_training_data.ml` without
  touching `Gbt_strategy.ml`.

The fix is in the source, not in the model file. Never rename
columns in the text dump — it silently decouples training from
inference.

### `Invalid value for field: Price` at order placement

Unrelated to the model — see `docs/architecture/ml/gbt.md`'s
sibling note on MOEX tick-size and price-band handling. GBT
picks direction; the live engine and ACL are responsible for
snapping qty to `lot_size` and price to `min_step`.

### Accuracy stuck at random (≈ 0.33) across folds

The three-class labels carry almost no signal at this horizon /
threshold combination. Things to try:

- Wider threshold band (0.01 – 0.02) — cuts "flat" noise and
  leaves cleaner up/down signals.
- Longer horizon (10 – 20 bars) — short-term noise averages out.
- More features — lagged returns `r_{t-1}, r_{t-5}`, volume
  ratio, MACD histogram. These need both columns added to
  `export_training_data.ml` *and* corresponding updates to
  `Gbt_strategy.feature_names` + feature assembly.

### Label distribution heavily skewed

If `{0: 8000, 1: 500, 2: 116}` kind of split, the band is too
narrow for the instrument's typical moves (most bars don't cross
the threshold). Widen `--threshold`; a rule of thumb is to aim
for roughly equal thirds so the model actually has to
discriminate.

### Model file is huge / very slow to load

LightGBM can easily produce a 10 MB text dump for a small CSV if
trees aren't pruned. Tighten `num_leaves`, `max_depth`,
`min_data_in_leaf`, or reduce `num_boost_round` ceiling. The
OCaml parser is O(n) in file size but there's no reason to
feed it a bloated model.

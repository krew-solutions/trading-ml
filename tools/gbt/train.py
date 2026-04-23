#!/usr/bin/env python3
"""Train a LightGBM 3-class classifier on exported trading data.

Input:  CSV with header [rsi, mfi, bb_pct_b, label] produced by
        ``bin/export_training_data.exe``.
Output: LightGBM text-format model readable by the OCaml
        ``Gbt.Gbt_model.of_file`` loader.

Validation uses walk-forward cross-validation
(``sklearn.model_selection.TimeSeriesSplit``). Standard K-fold
shuffling is wrong for time-series — it leaks future data into
training folds and yields an optimistic accuracy that evaporates
in production.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.model_selection import TimeSeriesSplit


# Must stay in lockstep with Strategies.Gbt_strategy.feature_names
# on the OCaml side. If you add a feature, update BOTH and the
# export_training_data tool's column writer.
EXPECTED_FEATURES = ["rsi", "mfi", "bb_pct_b"]
LABEL_COL = "label"
NUM_CLASSES = 3


DEFAULT_PARAMS = {
    "objective":        "multiclass",
    "num_class":        NUM_CLASSES,
    "metric":           "multi_logloss",
    "learning_rate":    0.03,
    "num_leaves":       31,
    "max_depth":        5,
    "min_data_in_leaf": 200,
    "feature_fraction": 0.8,
    "bagging_fraction": 0.8,
    "bagging_freq":     5,
    "verbose":          -1,
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Train a GBT model on exported trading data.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--input", required=True, type=Path,
                   help="CSV produced by bin/export_training_data.exe")
    p.add_argument("--output", required=True, type=Path,
                   help="Path to write the LightGBM text-dump model")
    p.add_argument("--n-splits", type=int, default=5,
                   help="Walk-forward CV folds")
    p.add_argument("--num-boost-round", type=int, default=500,
                   help="Max boosting rounds; early stopping may cut earlier")
    p.add_argument("--early-stopping", type=int, default=30,
                   help="Rounds w/o validation improvement before stopping")
    p.add_argument("--learning-rate", type=float,
                   default=DEFAULT_PARAMS["learning_rate"])
    p.add_argument("--num-leaves", type=int,
                   default=DEFAULT_PARAMS["num_leaves"])
    p.add_argument("--max-depth", type=int,
                   default=DEFAULT_PARAMS["max_depth"])
    p.add_argument("--min-data-in-leaf", type=int,
                   default=DEFAULT_PARAMS["min_data_in_leaf"])
    p.add_argument("--seed", type=int, default=42,
                   help="Random seed for reproducibility")
    p.add_argument("--params-json", type=Path,
                   help="JSON file with LightGBM param overrides; "
                        "merged over the CLI defaults")
    p.add_argument("--final-fraction", type=float, default=1.0,
                   help="Fraction of the tail to train the final model on "
                        "[0..1]; 0.5 = last 50%% (recency bias), "
                        "1.0 = full history")
    return p.parse_args()


def load_dataset(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    missing = [c for c in EXPECTED_FEATURES + [LABEL_COL]
               if c not in df.columns]
    if missing:
        raise SystemExit(
            f"Missing columns: {missing}; got {list(df.columns)}")
    df = df.dropna()
    return df.reset_index(drop=True)


def label_stats(y: np.ndarray) -> str:
    vc = pd.Series(y).value_counts().sort_index()
    total = len(y)
    return ", ".join(f"{k}={v} ({v/total:.1%})" for k, v in vc.items())


def walk_forward_cv(
    X: np.ndarray,
    y: np.ndarray,
    features: list[str],
    params: dict,
    n_splits: int,
    num_boost_round: int,
    early_stopping: int,
) -> tuple[list[float], list[int]]:
    """Run ``TimeSeriesSplit`` CV, training one model per fold.
    Returns per-fold accuracy and best-iteration numbers."""
    accs: list[float] = []
    best_iters: list[int] = []
    for i, (tr_idx, te_idx) in enumerate(
            TimeSeriesSplit(n_splits=n_splits).split(X), 1):
        train_set = lgb.Dataset(
            X[tr_idx], y[tr_idx], feature_name=features,
            free_raw_data=False)
        valid_set = lgb.Dataset(
            X[te_idx], y[te_idx], feature_name=features,
            free_raw_data=False, reference=train_set)
        model = lgb.train(
            params,
            train_set,
            num_boost_round=num_boost_round,
            valid_sets=[valid_set],
            callbacks=[
                lgb.early_stopping(early_stopping, verbose=False),
                lgb.log_evaluation(0),
            ],
        )
        preds = model.predict(X[te_idx]).argmax(axis=1)
        acc = float((preds == y[te_idx]).mean())
        print(f"  fold {i}/{n_splits}: "
              f"train={len(tr_idx):>6}  test={len(te_idx):>6}  "
              f"acc={acc:.4f}  best_iter={model.best_iteration}")
        accs.append(acc)
        best_iters.append(int(model.best_iteration))
    return accs, best_iters


def train_final(
    X: np.ndarray,
    y: np.ndarray,
    features: list[str],
    params: dict,
    num_boost_round: int,
    final_fraction: float,
) -> lgb.Booster:
    n = len(X)
    start = int(n * max(0.0, min(1.0, 1 - final_fraction)))
    Xf, yf = X[start:], y[start:]
    print(f"\nFinal model: rows [{start}:{n}] ({len(Xf)} rows) "
          f"× {num_boost_round} rounds")
    train_set = lgb.Dataset(Xf, yf, feature_name=features)
    return lgb.train(params, train_set, num_boost_round=num_boost_round)


def main() -> int:
    args = parse_args()

    # Build params: DEFAULT ← CLI overrides ← JSON overrides.
    params = dict(DEFAULT_PARAMS)
    params["learning_rate"] = args.learning_rate
    params["num_leaves"] = args.num_leaves
    params["max_depth"] = args.max_depth
    params["min_data_in_leaf"] = args.min_data_in_leaf
    params["seed"] = args.seed
    if args.params_json:
        params.update(json.loads(args.params_json.read_text()))

    df = load_dataset(args.input)
    X = df[EXPECTED_FEATURES].values
    y = df[LABEL_COL].values.astype(int)

    print(f"Input:    {args.input}  ({len(df)} rows)")
    print(f"Features: {EXPECTED_FEATURES}")
    print(f"Labels:   {label_stats(y)}")

    if any(y < 0) or any(y >= NUM_CLASSES):
        raise SystemExit(
            f"Labels must lie in [0..{NUM_CLASSES-1}]; "
            f"got min={int(y.min())} max={int(y.max())}")

    print(f"\n=== Walk-forward CV ({args.n_splits} splits) ===")
    accs, best_iters = walk_forward_cv(
        X, y, EXPECTED_FEATURES, params,
        n_splits=args.n_splits,
        num_boost_round=args.num_boost_round,
        early_stopping=args.early_stopping,
    )
    baseline = 1 / NUM_CLASSES
    mean_acc = float(np.mean(accs))
    print(f"\n  mean acc = {mean_acc:.4f} (±{np.std(accs):.4f})")
    print(f"  baseline = {baseline:.4f} (random 3-class)")
    print(f"  lift     = {(mean_acc - baseline) * 100:+.2f} pp")
    print(f"  best_iter by fold = {best_iters} "
          f"(median {int(np.median(best_iters))})")

    final_rounds = max(50, int(np.median(best_iters)))
    model = train_final(
        X, y, EXPECTED_FEATURES, params,
        num_boost_round=final_rounds,
        final_fraction=args.final_fraction,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save_model(str(args.output))
    size = args.output.stat().st_size
    print(f"\nSaved → {args.output}  ({size:,} bytes, "
          f"{model.num_trees()} trees)")

    print("\n=== Feature importance (gain) ===")
    imps = model.feature_importance(importance_type="gain")
    total = float(sum(imps)) or 1.0
    for name, imp in sorted(zip(EXPECTED_FEATURES, imps),
                            key=lambda kv: -kv[1]):
        print(f"  {name:<12} gain={imp:>10.1f}  ({imp/total:.1%})")

    return 0


if __name__ == "__main__":
    sys.exit(main())

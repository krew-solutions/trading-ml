#!/usr/bin/env python3
"""Evaluate a LightGBM model against a CSV dataset.

Useful for monitoring drift on a deployed model: freshly export
recent data via ``bin/export_training_data.exe``, point this
script at it, and compare accuracy to the original training
baseline. A persistent drop is the signal to retrain.

Does not modify the model.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd


EXPECTED_FEATURES = ["rsi", "mfi", "bb_pct_b"]
LABEL_COL = "label"
NUM_CLASSES = 3


def main() -> int:
    p = argparse.ArgumentParser(
        description="Evaluate a GBT model on CSV data.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--model", required=True, type=Path,
                   help="LightGBM text-dump produced by train.py")
    p.add_argument("--input", required=True, type=Path,
                   help="CSV with the same schema as training data")
    p.add_argument("--top-n", type=int, default=10,
                   help="Show first N predictions for spot-checking")
    args = p.parse_args()

    model = lgb.Booster(model_file=str(args.model))
    print(f"Model: {args.model}")
    print(f"  trees={model.num_trees()}  "
          f"features={model.num_feature()}  "
          f"feature_name={model.feature_name()}")

    if model.feature_name() != EXPECTED_FEATURES:
        print(f"\nWARNING: model features {model.feature_name()} "
              f"!= strategy expectation {EXPECTED_FEATURES}",
              file=sys.stderr)

    df = pd.read_csv(args.input).dropna()
    missing = [c for c in EXPECTED_FEATURES + [LABEL_COL]
               if c not in df.columns]
    if missing:
        raise SystemExit(f"CSV missing columns: {missing}")
    X = df[EXPECTED_FEATURES].values
    y = df[LABEL_COL].values.astype(int)

    probs = model.predict(X)
    pred = probs.argmax(axis=1)
    acc = float((pred == y).mean())
    baseline = 1 / NUM_CLASSES

    print(f"\nRows:     {len(df)}")
    print(f"Accuracy: {acc:.4f}")
    print(f"Baseline: {baseline:.4f}  (random {NUM_CLASSES}-class)")
    print(f"Lift:     {(acc - baseline) * 100:+.2f} pp")

    # Confusion matrix: rows = actual label, cols = predicted.
    cm = np.zeros((NUM_CLASSES, NUM_CLASSES), dtype=int)
    for actual, predicted in zip(y, pred):
        cm[actual][predicted] += 1
    print("\nConfusion matrix (rows=actual, cols=predicted):")
    print("         pred=0   pred=1   pred=2   row_total")
    for i in range(NUM_CLASSES):
        row = cm[i]
        total = int(row.sum())
        cells = "  ".join(f"{c:>6}" for c in row)
        print(f"  act={i}   {cells}   {total:>8}")

    # Per-class precision / recall.
    print("\nPer-class metrics:")
    print("           precision  recall    support")
    for c in range(NUM_CLASSES):
        tp = cm[c][c]
        fp = cm[:, c].sum() - tp
        fn = cm[c, :].sum() - tp
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall    = tp / (tp + fn) if (tp + fn) else 0.0
        support   = int(cm[c, :].sum())
        print(f"  class={c}  {precision:.4f}     {recall:.4f}    {support}")

    print(f"\nSample predictions (first {min(args.top_n, len(df))}):")
    print("    actual  pred   P(0)    P(1)    P(2)")
    for i in range(min(args.top_n, len(df))):
        print(f"    {y[i]:>6}  {pred[i]:>4}   "
              f"{probs[i][0]:.4f}  {probs[i][1]:.4f}  {probs[i][2]:.4f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

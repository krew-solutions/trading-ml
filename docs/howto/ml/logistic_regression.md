# How to train and deploy a logistic gate

End-to-end walkthrough: take a set of existing heuristic
strategies (SMA crossover, RSI mean reversion, etc.), learn a
logistic classifier that decides **when to trust their
consensus**, and deploy the result as a `Composite.Learned`
policy.

For design background see
[architecture/ml/logistic_regression.md](../../architecture/ml/logistic_regression.md).
This document assumes you've read it and focuses on the
mechanics.

The logistic pipeline is dramatically smaller than the
[GBT one](gbt.md): training happens in-process in OCaml, weights
are ~10 scalars, no Python, no `.meta.json` sidecar, no
hot-reload watcher. The whole loop — "construct children, fit,
use" — is a dozen lines of OCaml.

## What you're actually training

A common misconception: "logistic regression replaces my heuristic
strategies with an ML model". It doesn't. Its job is to **gate**
their signals — given that SMA Crossover, RSI Mean Reversion,
MACD Momentum and Bollinger Breakout all emit their opinions on
a bar, logistic decides whether their collective opinion is
reliable *right now* (given the market regime).

Concretely the input features are:

- `(signal, strength)` pair from each child strategy
- `volatility` (coefficient of variation of recent closes)
- `volume_ratio` (current volume / mean of recent volumes)

The output is `P(profitable)`: probability that entering long on
the next bar yields a positive return over the lookahead window.
`Composite.Learned` treats this as `Enter_long if P > threshold,
else Hold`.

The rule logistic can learn — and that plain `Adaptive` /
`Majority` policies cannot — is **regime-conditional trust**:
"children collectively work in low-volatility periods but
misfire when vol spikes". Whether that rule is actually present
in your data is the empirical question the trainer answers.

## Prerequisites

None outside the OCaml build. No Python, no venv, no separate
CLI tool. Just `dune build`.

## Minimal working example

Put this in a scratch file (say `bin/train_logistic.ml`):

```ocaml
open Core

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();

  (* 1. Pull historical bars from whichever broker you have creds for. *)
  let instrument = Instrument.of_qualified "SBER@MISX" in
  let rest =
    let cfg = Finam.Config.make
      ~account_id:(Sys.getenv "FINAM_ACCOUNT_ID")
      ~secret:(Sys.getenv "FINAM_SECRET") () in
    Finam.Rest.make ~transport:(Http_transport.make_eio ~env) ~cfg
  in
  let candles = Finam.Rest.bars rest ~n:5000 ~instrument ~timeframe:H1 in
  Printf.printf "Loaded %d candles\n%!" (List.length candles);

  (* 2. Construct the child strategies whose signals the classifier
        will learn to gate. Order matters — the feature vector
        encodes them by position. *)
  let children = [
    Strategies.Strategy.default (module Strategies.Sma_crossover);
    Strategies.Strategy.default (module Strategies.Rsi_mean_reversion);
    Strategies.Strategy.default (module Strategies.Macd_momentum);
    Strategies.Strategy.default (module Strategies.Bollinger_breakout);
  ] in

  (* 3. Fit. 70/30 walk-forward split happens inside [Trainer.train];
        see architecture doc for label derivation. *)
  let result = Logistic_regression.Trainer.train
    ~children ~candles
    ~lookahead:5
    ~epochs:10
    ~lr:0.01
    ~l2:1e-4
    ~context_window:20
    ()
  in
  Printf.printf "Training: n_train=%d n_val=%d train_loss=%.4f val_loss=%.4f\n%!"
    result.n_train result.n_val
    result.train_loss result.val_loss;

  (* 4. Print the weights so you can hard-code them into a config
        or paste into a test fixture. *)
  Printf.printf "Weights = [| %s |]\n%!"
    (Array.to_list result.weights
     |> List.map (Printf.sprintf "%.6f")
     |> String.concat "; ")
```

Register the binary in `bin/dune` under the existing
`executables` stanza by adding `train_logistic` to `names`, then
build and run:

```bash
dune build
dune exec -- bin/train_logistic.exe
```

Typical output (numbers vary with data):

```
Loaded 5000 candles
Training: n_train=1342 n_val=575 train_loss=0.6782 val_loss=0.6891
Weights = [| 0.023451; -0.158234; 0.087621; 0.212345; -0.034567; ... |]
```

## Interpreting the result

- **`n_train` / `n_val`** — how many bars contributed a labelled
  example. Bars where every child said `Hold` are skipped
  (nothing to learn from); bars inside the last `lookahead`
  slice are skipped too (no ground truth yet). A low count
  (`n_train < 100`) means the trainer couldn't find enough
  decision points — increase history, pick more active children,
  or shorten `lookahead`.

- **`train_loss` / `val_loss`** — cross-entropy log-loss.
  Baseline for a 2-class problem is `ln 2 ≈ 0.693` (a model
  that always predicts 0.5). Val loss significantly below 0.69
  is signal; val loss > train loss by more than a few percent
  is overfitting (bump `l2`, drop `epochs`).

- **Weights** — first scalar is bias, rest are per-feature. The
  feature layout is documented in
  [architecture/ml/logistic_regression.md](../../architecture/ml/logistic_regression.md#feature-vector):
  interleaved `(signal, strength)` per child, followed by
  `volatility` and `volume_ratio`. A large positive weight on
  `signal₁` means "trust child 1"; a large negative weight on
  `volatility` means "distrust everything when vol is high".

## Deploying the trained gate

Copy the printed weights into code or a config structure, then
construct `Composite.Learned` with a closure that marries
`Features.extract` + `Logistic.predict`:

```ocaml
let trained_weights = [|
  0.023451; -0.158234; 0.087621; 0.212345; -0.034567;
  (* ...paste from the trainer output, length = 2·n_children + 3... *)
|]

let logistic = Logistic_regression.Logistic.of_weights trained_weights

let predict ~signals ~candle ~recent_closes ~recent_volumes =
  let features = Logistic_regression.Features.extract
    ~signals ~candle ~recent_closes ~recent_volumes in
  Logistic_regression.Logistic.predict logistic features

let composite = Strategies.Strategy.make (module Strategies.Composite)
  Strategies.Composite.{
    policy = Learned { predict; threshold = 0.55 };
    children = [
      Strategies.Strategy.default (module Strategies.Sma_crossover);
      Strategies.Strategy.default (module Strategies.Rsi_mean_reversion);
      Strategies.Strategy.default (module Strategies.Macd_momentum);
      Strategies.Strategy.default (module Strategies.Bollinger_breakout);
    ];
  }
```

**Invariant: the child list here must match the child list passed
to the trainer, in the same order.** The weights index into the
feature vector positionally, and a reorder silently corrupts
predictions. If you add a child, retrain from scratch — the
weight vector's length changes.

Feed the resulting `composite` into `Backtest.run` or a
`Live_engine.config` exactly like any other strategy. Nothing
downstream cares that it's ML-backed.

## Persistence

Weights are a plain `float array`. For anything persistent you'd
serialise them alongside the strategy config:

```ocaml
(* to JSON *)
let weights_to_json weights : Yojson.Safe.t =
  `List (Array.to_list weights |> List.map (fun f -> `Float f))

(* from JSON *)
let weights_of_json = function
  | `List xs -> xs |> List.map (function
      | `Float f -> f
      | `Int n -> float_of_int n
      | _ -> invalid_arg "weights_of_json: expected number") |> Array.of_list
  | _ -> invalid_arg "weights_of_json: expected list"
```

No hot-reload machinery like GBT's `mtime`-watch — the weights
are compiled into the binary (or read once at startup). If you
retrain and want the new weights in production, restart the
process. For a 10-scalar vector, that's a reasonable trade-off;
if weights live in a config file and change often, add your own
reload hook.

## Known gap: offline training data

Right now there's no CLI tool that dumps candles to disk for
offline logistic training, the way
[`bin/export_training_data.exe`](../../../bin/export_training_data.ml)
does for GBT. The trainer takes an in-memory `Candle.t list`, so
the natural place to run it is a long-lived OCaml script (as in
the example above) that fetches bars and immediately trains.

Two plausible workflows depending on iteration speed:

1. **Embedded**: the `train_logistic.ml` binary is your
   "notebook" — edit child list / hyperparameters, run, paste
   weights into production code, commit.

2. **Long-running research process**: inside a REPL
   (`dune utop`), construct children, load candles, call
   `Trainer.train` with various configs. No disk involvement;
   iterate by re-running in the same utop session.

If you want a nautilus-style offline artifact (`weights.json` on
disk), add a wrapper that reads a CSV of candles + writes a JSON
file — ~30 lines of OCaml, hasn't been necessary yet because the
training time is seconds.

## Troubleshooting

### `val_loss == Float.infinity`

The dataset had fewer than 10 labelled rows. See the
`n_total < 10` branch in
[`trainer.ml`](../../../lib/domain/ml/logistic_regression/trainer.ml).
Causes:

- Too few candles (tens instead of hundreds)
- Every child Hold'ed every bar (child params too conservative,
  or strategies genuinely silent on the period)
- Lookahead too large (tail bars dropped exhaust the dataset)

### `val_loss > train_loss + 0.05` — overfitting

- Raise `l2` (try 1e-3 or 1e-2)
- Drop `epochs` (try 3-5 instead of 10)
- More data, especially held-out

### `val_loss ≈ train_loss ≈ 0.693` — not learning

Baseline log-loss for coin-flip prediction. The classifier
can't beat random. Options:

- The signal genuinely isn't there — try different children,
  different lookahead, different instrument.
- Learning rate too high, oscillating. Drop `lr` to 0.001.
- Feature scaling — all features are in similar ranges by
  design (`[-1, 1]` for signals, `[0, 1]` for strengths,
  `[0, ∞)` for volatility/volume_ratio), but extreme volume
  spikes could swamp the others. Consider clipping.

### Weights have NaN / inf

`lr` too high caused a gradient explosion, or `candles` has NaN
prices somewhere upstream. Inspect `candles` first; if clean,
drop `lr` by 10×.

## Compared to GBT

The GBT pipeline is heavier because the trade-off is different:

- GBT learns richer non-linear interactions and gives
  standalone class predictions (direct up/flat/down signals,
  not a gate).
- Logistic learns a linear combination of child signals — less
  expressive, but trains in seconds, fits in 10 numbers, and
  doesn't need Python.

If you have strong heuristic children already and want to combine
them smarter, start with logistic. If you want the model to
**replace** the heuristics and discover patterns from raw
indicators, go to [GBT](gbt.md).

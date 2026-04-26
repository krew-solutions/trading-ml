(** GBT-driven strategy. Thin wrapper around a pre-trained
    LightGBM model (loaded via {!Gbt.Gbt_model}) that turns
    per-bar feature vectors into {!Signal.t} decisions.

    Expected model shape:
    - objective: {!Gbt.Gbt_model.Multiclass}[ 3]
    - classes: [0 = down, 1 = flat, 2 = up]
    - feature_names exactly matches the strategy's feature roster
      (see [feature_names] below), in the same order. Mismatch
      fails at [init] — silently garbaging predictions is worse
      than a startup crash.

    Features computed per bar (see {!feature_names} for the canonical
    order — any training pipeline must emit columns identically):
    - [rsi]          oversold/overbought momentum, scaled to [0..1]
    - [mfi]          volume-weighted MFI, scaled to [0..1]
    - [bb_pct_b]     Bollinger %B: [(close - lower) / (upper - lower)]
    - [macd_hist]    MACD(12,26,9) histogram — fast_ema - slow_ema - signal
    - [volume_ratio] [volume / VolumeMA(20)]; proxy for "bar is unusually active"
    - [lag_return_5] [log(close[t] / close[t-5])] — 5-bar log return
    - [chaikin_osc]  Chaikin Oscillator (3, 10): MACD-style momentum of
                     the A/D line; centered near zero by construction
    - [ad_slope_10]  normalized 10-bar rate of change of the
                     cumulative A/D line: [(ad[t] - ad[t-10]) /
                     (|ad[t-10]| + 1)]. Raw A/D drifts unbounded with
                     time and would make the model non-stationary;
                     this ratio keeps the feature on a fixed scale.

    All indicator periods (MACD / VolumeMA / Chaikin / lag windows)
    are standard and hard-coded on the strategy side. Non-default
    settings would require a matching retraining, so keeping them
    non-parametric avoids the silent-drift footgun of mismatched
    training vs inference. *)

open Core

type params = {
  model_path : string;
  enter_threshold : float;
      (** Minimum winning-class probability required to fire an entry
      signal. Sensible range [0.5, 0.8]; lower = more trades, more
      noise; higher = fewer but higher-confidence. *)
  allow_short : bool;
  rsi_period : int;
  mfi_period : int;
  bb_period : int;
  bb_k : float;
}

type state

val name : string
val default_params : params

val feature_names : string array
(** The feature-name roster the strategy constructs per bar. A
    loaded {!Gbt.Gbt_model.t}'s [feature_names] must equal this
    array in the same order — that's the contract a training
    pipeline must honour. *)

val init : params -> state
(** Loads and parses the model at [params.model_path]. Raises
    [Invalid_argument] if the file is missing, malformed, has a
    non-multiclass objective, or carries a feature-name set that
    disagrees with {!feature_names}. *)

val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t

open Core

type params = {
  model_path : string;
  enter_threshold : float;
  allow_short : bool;
  rsi_period : int;
  mfi_period : int;
  bb_period : int;
  bb_k : float;
}

type position = Flat | Long | Short

type state = {
  params : params;
  model : Gbt.Gbt_model.t;
  model_mtime : float;
  rsi : Indicators.Indicator.t;
  mfi : Indicators.Indicator.t;
  bb : Indicators.Indicator.t;
  macd : Indicators.Indicator.t;
  volume_ma : Indicators.Indicator.t;
  ad : Indicators.Indicator.t;
  chaikin : Indicators.Indicator.t;
  (* Past closes for the 5-bar lag return feature. Capacity is
     exactly [lag_return_bars]; when full, [oldest] is [close[t-5]]
     and we compute [log(close[t] / close[t-5])] before pushing
     the new close. *)
  close_history : float Indicators.Ring.t;
  (* Past A/D values for the 10-bar A/D slope feature. Same
     "read oldest, then push" discipline as [close_history]. *)
  ad_history : float Indicators.Ring.t;
  position : position;
}

(** Standard MACD triple; these are industry defaults and aren't
    parametric on the strategy side — a training pipeline that
    wants non-default MACD settings would need a matching model
    retraining, so keeping them hard-coded is the honest stance.
    Same reasoning for the Chaikin Oscillator's (3, 10) and the
    A/D slope window. *)
let macd_fast, macd_slow, macd_signal = (12, 26, 9)

let volume_ma_period = 20
let lag_return_bars = 5
let chaikin_fast, chaikin_slow = (3, 10)
let ad_slope_bars = 10

let name = "GBT"

let default_params =
  {
    model_path = "";
    enter_threshold = 0.55;
    allow_short = false;
    rsi_period = 14;
    mfi_period = 14;
    bb_period = 20;
    bb_k = 2.0;
  }

(** The strategy's canonical feature ordering. Training pipelines
    must emit columns in exactly this order; the model file's
    [feature_names] array is cross-checked against this at [init].

    - [rsi]          oversold/overbought momentum, scaled to [0..1]
    - [mfi]          volume-weighted MFI, scaled to [0..1]
    - [bb_pct_b]     %B position within Bollinger bands
    - [macd_hist]    MACD histogram (fast EMA − slow EMA − signal EMA)
    - [volume_ratio] [volume / VolumeMA(20)], proxy for "unusual bar"
    - [lag_return_5] log return over the past 5 bars *)
let feature_names =
  [|
    "rsi";
    "mfi";
    "bb_pct_b";
    "macd_hist";
    "volume_ratio";
    "lag_return_5";
    "chaikin_osc";
    "ad_slope_10";
  |]

let validate_model_shape (m : Gbt.Gbt_model.t) : unit =
  (match m.objective with
  | Multiclass 3 -> ()
  | _ ->
      invalid_arg
        "Gbt_strategy: model objective must be Multiclass(3) with classes [0=down; \
         1=flat; 2=up]");
  if
    Array.length m.feature_names <> Array.length feature_names
    || not (Array.for_all2 (fun a b -> a = b) m.feature_names feature_names)
  then
    invalid_arg
      (Printf.sprintf
         "Gbt_strategy: model feature_names mismatch — strategy expects [%s], model has \
          [%s]"
         (String.concat ", " (Array.to_list feature_names))
         (String.concat ", " (Array.to_list m.feature_names)))

(** Load-and-validate helper — parses the text dump, asserts the
    [Multiclass 3] + [feature_names] contract, and returns the
    model plus its file mtime. Used by both [init] and the hot-
    reload path, so validation errors are surfaced uniformly. *)
let load_model (path : string) : Gbt.Gbt_model.t * float =
  let m = Gbt.Gbt_model.of_file path in
  validate_model_shape m;
  let mtime = Option.value (Gbt.Gbt_model.file_mtime path) ~default:0.0 in
  (m, mtime)

let init p =
  if p.model_path = "" then invalid_arg "Gbt_strategy: model_path must be set";
  if p.rsi_period <= 1 then invalid_arg "Gbt_strategy: rsi_period > 1";
  if p.mfi_period <= 1 then invalid_arg "Gbt_strategy: mfi_period > 1";
  if p.bb_period <= 1 then invalid_arg "Gbt_strategy: bb_period > 1";
  if p.enter_threshold < 0.34 || p.enter_threshold > 1.0 then
    invalid_arg "Gbt_strategy: enter_threshold in (0.34, 1.0]";
  let model, model_mtime = load_model p.model_path in
  {
    params = p;
    model;
    model_mtime;
    rsi = Indicators.Rsi.make ~period:p.rsi_period;
    mfi = Indicators.Mfi.make ~period:p.mfi_period;
    bb = Indicators.Bollinger.make ~period:p.bb_period ~k:p.bb_k ();
    macd = Indicators.Macd.make ~fast:macd_fast ~slow:macd_slow ~signal:macd_signal ();
    volume_ma = Indicators.Volume_ma.make ~period:volume_ma_period;
    ad = Indicators.Ad.make ();
    chaikin = Indicators.Chaikin_oscillator.make ~fast:chaikin_fast ~slow:chaikin_slow ();
    close_history = Indicators.Ring.create ~capacity:lag_return_bars 0.0;
    ad_history = Indicators.Ring.create ~capacity:ad_slope_bars 0.0;
    position = Flat;
  }

(** Hot-reload hook. Between bars the training cron may have
    atomically rename'd a fresh model into place — poll [mtime]
    before each prediction and swap in the new model if it's
    newer than what we have in memory. A parse failure on the new
    file (half-written, format drift, feature-name mismatch)
    raises; there's no "silent fallback to old model" because
    that would mask the drift indefinitely — fail visibly and let
    supervision decide whether to halt or restart. Transient stat
    failures (file briefly missing mid-rename) are a non-event
    and leave [st] unchanged. *)
let maybe_reload (st : state) : state =
  match Gbt.Gbt_model.file_mtime st.params.model_path with
  | Some mtime when mtime > st.model_mtime ->
      let model, model_mtime = load_model st.params.model_path in
      { st with model; model_mtime }
  | _ -> st

(** Extract a scalar indicator output or [None] during warm-up. *)
let scalar_1 ind =
  match Indicators.Indicator.value ind with
  | Some (_, [ v ]) -> Some v
  | _ -> None

(** Bollinger %B: normalized position of [close] within the bands.
    0.0 = on lower band, 1.0 = on upper, can exceed either way. *)
let bb_pct_b ind close =
  match Indicators.Indicator.value ind with
  | Some (_, [ lower; _middle; upper ]) ->
      let range = upper -. lower in
      if range = 0.0 then None else Some ((close -. lower) /. range)
  | _ -> None

(** MACD histogram — third output of {!Indicators.Macd}. *)
let macd_hist_of ind =
  match Indicators.Indicator.value ind with
  | Some (_, [ _macd; _signal; hist ]) -> Some hist
  | _ -> None

let on_candle st instrument (c : Candle.t) =
  let st = maybe_reload st in
  let rsi = Indicators.Indicator.update st.rsi c in
  let mfi = Indicators.Indicator.update st.mfi c in
  let bb = Indicators.Indicator.update st.bb c in
  let macd = Indicators.Indicator.update st.macd c in
  let volume_ma = Indicators.Indicator.update st.volume_ma c in
  let ad = Indicators.Indicator.update st.ad c in
  let chaikin = Indicators.Indicator.update st.chaikin c in
  let close = Decimal.to_float c.Candle.close in
  let volume = Decimal.to_float c.Candle.volume in
  (* Lag return: compare current close against the oldest in the
     history ring BEFORE pushing — once we push, oldest becomes
     [close[t-4]] for next bar, which is wrong. *)
  let lag_return_opt =
    if Indicators.Ring.is_full st.close_history then
      let old_close = Indicators.Ring.oldest st.close_history in
      if old_close > 0.0 then Some (log (close /. old_close)) else None
    else None
  in
  let close_history = Indicators.Ring.push st.close_history close in
  (* A/D 10-bar slope, normalized: the A/D line is cumulative so
     its raw value drifts unbounded with time; feeding [ad[t] -
     ad[t-10]] relative to [|ad[t-10]| + 1] keeps the feature on a
     stationary scale regardless of the series' absolute level. *)
  let ad_slope_opt, ad_history =
    match scalar_1 ad with
    | None -> (None, st.ad_history)
    | Some ad_now ->
        let slope =
          if Indicators.Ring.is_full st.ad_history then
            let old_ad = Indicators.Ring.oldest st.ad_history in
            Some ((ad_now -. old_ad) /. (Float.abs old_ad +. 1.0))
          else None
        in
        (slope, Indicators.Ring.push st.ad_history ad_now)
  in
  let st =
    { st with rsi; mfi; bb; macd; volume_ma; ad; chaikin; close_history; ad_history }
  in
  let volume_ratio_opt =
    match scalar_1 volume_ma with
    | Some vma when vma > 0.0 -> Some (volume /. vma)
    | _ -> None
  in
  match
    ( scalar_1 rsi,
      scalar_1 mfi,
      bb_pct_b bb close,
      macd_hist_of macd,
      volume_ratio_opt,
      lag_return_opt,
      scalar_1 chaikin,
      ad_slope_opt )
  with
  | Some rsi_v, Some mfi_v, Some pctb, Some mh, Some vr, Some lr, Some co, Some ads ->
      (* Scale RSI/MFI to [0..1] so all features share roughly the
       same range — GBT is tree-based and scale-insensitive, but
       symmetry helps humans reading feature importances. *)
      let features = [| rsi_v /. 100.0; mfi_v /. 100.0; pctb; mh; vr; lr; co; ads |] in
      let probs = Gbt.Gbt_model.predict_class_probs st.model ~features in
      let argmax =
        let best = ref 0 in
        for i = 1 to Array.length probs - 1 do
          if probs.(i) > probs.(!best) then best := i
        done;
        !best
      in
      let conf = probs.(argmax) in
      let strength = Float.min 1.0 (Float.max 0.0 conf) in
      let confident = conf >= st.params.enter_threshold in
      let action, position, reason =
        match (argmax, confident, st.position) with
        | 2, true, Flat -> (Signal.Enter_long, Long, "GBT class=up")
        | 2, true, Short -> (Signal.Enter_long, Long, "GBT class=up (flip)")
        | 0, true, Flat when st.params.allow_short ->
            (Signal.Enter_short, Short, "GBT class=down")
        | 0, true, Long when st.params.allow_short ->
            (Signal.Enter_short, Short, "GBT class=down (flip)")
        | 0, true, Long -> (Signal.Exit_long, Flat, "GBT class=down")
        | _ -> (Signal.Hold, st.position, "")
      in
      let sig_ =
        {
          Signal.ts = c.Candle.ts;
          instrument;
          action;
          strength;
          stop_loss = None;
          take_profit = None;
          reason;
        }
      in
      ({ st with position }, sig_)
  | _ ->
      (* Warm-up: at least one indicator still accumulating. *)
      (st, Signal.hold ~ts:c.Candle.ts ~instrument)

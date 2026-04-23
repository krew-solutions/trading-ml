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
  rsi : Indicators.Indicator.t;
  mfi : Indicators.Indicator.t;
  bb : Indicators.Indicator.t;
  position : position;
}

let name = "GBT"

let default_params = {
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
    [feature_names] array is cross-checked against this at [init]. *)
let feature_names = [| "rsi"; "mfi"; "bb_pct_b" |]

let validate_model_shape (m : Gbt.Gbt_model.t) : unit =
  (match m.objective with
   | Multiclass 3 -> ()
   | _ ->
     invalid_arg
       "Gbt_strategy: model objective must be Multiclass(3) with \
        classes [0=down; 1=flat; 2=up]");
  if Array.length m.feature_names <> Array.length feature_names
  || not (Array.for_all2
            (fun a b -> a = b) m.feature_names feature_names) then
    invalid_arg (Printf.sprintf
      "Gbt_strategy: model feature_names mismatch — \
       strategy expects [%s], model has [%s]"
      (String.concat ", " (Array.to_list feature_names))
      (String.concat ", " (Array.to_list m.feature_names)))

let init p =
  if p.model_path = "" then
    invalid_arg "Gbt_strategy: model_path must be set";
  if p.rsi_period <= 1 then invalid_arg "Gbt_strategy: rsi_period > 1";
  if p.mfi_period <= 1 then invalid_arg "Gbt_strategy: mfi_period > 1";
  if p.bb_period <= 1 then invalid_arg "Gbt_strategy: bb_period > 1";
  if p.enter_threshold < 0.34 || p.enter_threshold > 1.0 then
    invalid_arg "Gbt_strategy: enter_threshold in (0.34, 1.0]";
  let model = Gbt.Gbt_model.of_file p.model_path in
  validate_model_shape model;
  {
    params = p;
    model;
    rsi = Indicators.Rsi.make ~period:p.rsi_period;
    mfi = Indicators.Mfi.make ~period:p.mfi_period;
    bb = Indicators.Bollinger.make ~period:p.bb_period ~k:p.bb_k ();
    position = Flat;
  }

(** Extract a scalar indicator output or [None] during warm-up. *)
let scalar_1 ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> Some v
  | _ -> None

(** Bollinger %B: normalized position of [close] within the bands.
    0.0 = on lower band, 1.0 = on upper, can exceed either way. *)
let bb_pct_b ind close =
  match Indicators.Indicator.value ind with
  | Some (_, [lower; _middle; upper]) ->
    let range = upper -. lower in
    if range = 0.0 then None
    else Some ((close -. lower) /. range)
  | _ -> None

let on_candle st instrument (c : Candle.t) =
  let rsi = Indicators.Indicator.update st.rsi c in
  let mfi = Indicators.Indicator.update st.mfi c in
  let bb  = Indicators.Indicator.update st.bb  c in
  let st = { st with rsi; mfi; bb } in
  let close = Decimal.to_float c.Candle.close in
  match scalar_1 rsi, scalar_1 mfi, bb_pct_b bb close with
  | Some rsi_v, Some mfi_v, Some pctb ->
    (* Scale RSI/MFI to [0..1] so all features share roughly the
       same range — GBT is tree-based and scale-insensitive, but
       symmetry helps humans reading feature importances. *)
    let features = [| rsi_v /. 100.0; mfi_v /. 100.0; pctb |] in
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
      match argmax, confident, st.position with
      | 2, true, Flat ->
        Signal.Enter_long, Long, "GBT class=up"
      | 2, true, Short ->
        Signal.Enter_long, Long, "GBT class=up (flip)"
      | 0, true, Flat when st.params.allow_short ->
        Signal.Enter_short, Short, "GBT class=down"
      | 0, true, Long when st.params.allow_short ->
        Signal.Enter_short, Short, "GBT class=down (flip)"
      | 0, true, Long ->
        Signal.Exit_long, Flat, "GBT class=down"
      | _ -> Signal.Hold, st.position, ""
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; instrument; action;
      strength; stop_loss = None; take_profit = None; reason;
    } in
    { st with position }, sig_
  | _ ->
    (* Warm-up: at least one indicator still accumulating. *)
    st, Signal.hold ~ts:c.Candle.ts ~instrument

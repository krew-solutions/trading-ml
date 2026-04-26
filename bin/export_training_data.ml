(** [export-training-data] — offline dataset builder for the GBT
    pipeline.

    Pulls historical bars from a broker, streams them through the
    same feature roster {!Strategies.Gbt_strategy} uses at inference
    (RSI / MFI / Bollinger %B), computes a three-class label from
    forward returns, and writes [features...,label] rows as CSV.
    The output is consumed by the Python training script
    ([docs/architecture/ml/gbt.md] has the full pipeline).

    Column alignment with the strategy is load-bearing: any drift
    between what this tool writes and what [Gbt_strategy] computes
    at inference silently garbages predictions. The fix is to keep
    the feature assembly in lockstep — if you change one, change
    both. *)

open Core
open Broker_boot

let usage () =
  prerr_endline
    {|export-training-data
  --broker finam|bcs --symbol SBER@MISX --output PATH
  [--timeframe M1|M5|M15|M30|H1|H4|D1] (default H1)
  [--from YYYY-MM-DD]    (default: --to minus 365 days)
  [--to   YYYY-MM-DD]    (default: now)
  [--label-mode threshold|triple-barrier]   (default threshold)

  threshold mode:
    [--horizon N]        (default 5 — bars ahead for label)
    [--threshold F]      (default 0.005 — ±band for 3-class label)

  triple-barrier mode (per de Prado):
    [--tp-mult F]        (default 1.5 — take-profit at close + tp_mult × ATR)
    [--sl-mult F]        (default 1.0 — stop-loss at close - sl_mult × ATR)
    [--timeout N]        (default 20 — bars to walk forward)
    ATR period is fixed at 14.

  [--secret S] [--account A] [--client-id C]  (or matching env vars)|};
  exit 2

(** [YYYY-MM-DD] or full ISO-8601; dates without a [T] suffix pick
    midnight UTC so the range boundaries are unambiguous. *)
let parse_date s =
  let s = if String.contains s 'T' then s else s ^ "T00:00:00Z" in
  Infra_common.Iso8601.parse s

let scalar_1 ind =
  match Indicators.Indicator.value ind with
  | Some (_, [ v ]) -> Some v
  | _ -> None

let bb_pct_b ind close =
  match Indicators.Indicator.value ind with
  | Some (_, [ lower; _middle; upper ]) ->
      let r = upper -. lower in
      if r = 0.0 then None else Some ((close -. lower) /. r)
  | _ -> None

let macd_hist_of ind =
  match Indicators.Indicator.value ind with
  | Some (_, [ _macd; _signal; hist ]) -> Some hist
  | _ -> None

type feature_row = {
  rsi : float;
  mfi : float;
  bb_pct_b : float;
  macd_hist : float;
  volume_ratio : float;
  lag_return_5 : float;
  chaikin_osc : float;
  ad_slope_10 : float;
}
(** Single-bar feature vector — same shape and order as
    [Strategies.Gbt_strategy.feature_names]. If any piece is still
    warming up (indicator returns [None] or the close-history ring
    is short of [lag_return_bars]) the whole row is [None]. *)

let lag_return_bars = 5
let ad_slope_bars = 10

(** Apply the GBT strategy's feature roster to every bar in [arr].
    Strict mirror of [Strategies.Gbt_strategy.on_candle]'s feature
    assembly — any drift between the two silently garbages the
    trained model. If you change one, change both. *)
let compute_features (arr : Candle.t array) : feature_row option array =
  let n = Array.length arr in
  let out = Array.make n None in
  let rsi_ = ref (Indicators.Rsi.make ~period:14) in
  let mfi_ = ref (Indicators.Mfi.make ~period:14) in
  let bb_ = ref (Indicators.Bollinger.make ~period:20 ~k:2.0 ()) in
  let macd_ = ref (Indicators.Macd.make ~fast:12 ~slow:26 ~signal:9 ()) in
  let vma_ = ref (Indicators.Volume_ma.make ~period:20) in
  let ad_ = ref (Indicators.Ad.make ()) in
  let chaikin_ = ref (Indicators.Chaikin_oscillator.make ~fast:3 ~slow:10 ()) in
  let close_ring_ = ref (Indicators.Ring.create ~capacity:lag_return_bars 0.0) in
  let ad_ring_ = ref (Indicators.Ring.create ~capacity:ad_slope_bars 0.0) in
  for i = 0 to n - 1 do
    let c = arr.(i) in
    rsi_ := Indicators.Indicator.update !rsi_ c;
    mfi_ := Indicators.Indicator.update !mfi_ c;
    bb_ := Indicators.Indicator.update !bb_ c;
    macd_ := Indicators.Indicator.update !macd_ c;
    vma_ := Indicators.Indicator.update !vma_ c;
    ad_ := Indicators.Indicator.update !ad_ c;
    chaikin_ := Indicators.Indicator.update !chaikin_ c;
    let close = Decimal.to_float c.Candle.close in
    let volume = Decimal.to_float c.Candle.volume in
    (* Read lag-return BEFORE pushing the current close — same
       ordering as [Gbt_strategy.on_candle]. *)
    let lag_opt =
      if Indicators.Ring.is_full !close_ring_ then
        let old = Indicators.Ring.oldest !close_ring_ in
        if old > 0.0 then Some (log (close /. old)) else None
      else None
    in
    close_ring_ := Indicators.Ring.push !close_ring_ close;
    let ad_slope_opt =
      match scalar_1 !ad_ with
      | None -> None
      | Some ad_now ->
          let slope =
            if Indicators.Ring.is_full !ad_ring_ then
              let old = Indicators.Ring.oldest !ad_ring_ in
              Some ((ad_now -. old) /. (Float.abs old +. 1.0))
            else None
          in
          ad_ring_ := Indicators.Ring.push !ad_ring_ ad_now;
          slope
    in
    let volume_ratio_opt =
      match scalar_1 !vma_ with
      | Some vma when vma > 0.0 -> Some (volume /. vma)
      | _ -> None
    in
    match
      ( scalar_1 !rsi_,
        scalar_1 !mfi_,
        bb_pct_b !bb_ close,
        macd_hist_of !macd_,
        volume_ratio_opt,
        lag_opt,
        scalar_1 !chaikin_,
        ad_slope_opt )
    with
    | Some r, Some m, Some b, Some mh, Some vr, Some lr, Some co, Some ads ->
        out.(i) <-
          Some
            {
              rsi = r /. 100.0;
              mfi = m /. 100.0;
              bb_pct_b = b;
              macd_hist = mh;
              volume_ratio = vr;
              lag_return_5 = lr;
              chaikin_osc = co;
              ad_slope_10 = ads;
            }
    | _ -> ()
  done;
  out

(** Separate pass for ATR — only used by the triple-barrier labeler.
    Period hard-coded to 14 (the Wilder default and the industry
    convention; exposing it as a CLI flag would force callers to
    keep training and labeler in lockstep, more rope than value). *)
let compute_atr (arr : Candle.t array) : float option array =
  let n = Array.length arr in
  let out = Array.make n None in
  let atr_ = ref (Indicators.Atr.make ~period:14) in
  for i = 0 to n - 1 do
    atr_ := Indicators.Indicator.update !atr_ arr.(i);
    out.(i) <- scalar_1 !atr_
  done;
  out

let csv_header =
  "ts,rsi,mfi,bb_pct_b,macd_hist,volume_ratio,lag_return_5,chaikin_osc,ad_slope_10,label\n"

let write_row oc (arr : Candle.t array) i (f : feature_row) label =
  Out_channel.output_string oc
    (Printf.sprintf "%Ld,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n" arr.(i).Candle.ts
       f.rsi f.mfi f.bb_pct_b f.macd_hist f.volume_ratio f.lag_return_5 f.chaikin_osc
       f.ad_slope_10 label)

(** Threshold label: compare [close[i + horizon]] against
    [close[i]], bucket into 3 classes by a symmetric ±threshold
    band. Path-insensitive. *)
let write_csv_threshold
    ~path
    ~horizon
    ~threshold
    (arr : Candle.t array)
    (feats : feature_row option array) =
  let n = Array.length arr in
  let oc = Out_channel.open_text path in
  Out_channel.output_string oc csv_header;
  let written = ref 0 in
  let skipped_warmup = ref 0 in
  for i = 0 to n - 1 - horizon do
    match feats.(i) with
    | None -> incr skipped_warmup
    | Some f ->
        let close_now = Decimal.to_float arr.(i).Candle.close in
        let close_future = Decimal.to_float arr.(i + horizon).Candle.close in
        let ret = (close_future -. close_now) /. close_now in
        let label = if ret > threshold then 2 else if ret < -.threshold then 0 else 1 in
        write_row oc arr i f label;
        incr written
  done;
  Out_channel.close oc;
  (!written, !skipped_warmup)

(** Triple-barrier label: see {!triple_barrier_label}. Drops rows
    where ATR is still warming up OR the forward walk would go
    past the array end. *)
let write_csv_triple_barrier
    ~path
    ~tp_mult
    ~sl_mult
    ~timeout
    (arr : Candle.t array)
    (feats : feature_row option array) =
  let atr = compute_atr arr in
  let n = Array.length arr in
  let oc = Out_channel.open_text path in
  Out_channel.output_string oc csv_header;
  let written = ref 0 in
  let skipped_warmup = ref 0 in
  let class_counts = [| 0; 0; 0 |] in
  for i = 0 to n - 1 - timeout do
    match feats.(i) with
    | None -> incr skipped_warmup
    | Some f -> (
        match Triple_barrier.label ~arr ~atr ~i ~tp_mult ~sl_mult ~timeout with
        | None -> incr skipped_warmup (* ATR not ready *)
        | Some label ->
            class_counts.(label) <- class_counts.(label) + 1;
            write_row oc arr i f label;
            incr written)
  done;
  Out_channel.close oc;
  Printf.printf "Triple-barrier class distribution: 0(down)=%d 1(flat)=%d 2(up)=%d\n%!"
    class_counts.(0) class_counts.(1) class_counts.(2);
  (!written, !skipped_warmup)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let require_arg name =
    match arg_value name args with
    | Some v -> v
    | None ->
        Printf.eprintf "export-training-data: %s is required\n" name;
        usage ()
  in
  let broker_id = require_arg "--broker" in
  let symbol = require_arg "--symbol" in
  let output = require_arg "--output" in
  let instrument = Instrument.of_qualified symbol in
  let timeframe =
    match arg_value "--timeframe" args with
    | Some s -> Timeframe.of_string s
    | None -> Timeframe.H1
  in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let to_ts =
    match arg_value "--to" args with
    | Some s -> parse_date s
    | None -> now_ts
  in
  let from_ts =
    match arg_value "--from" args with
    | Some s -> parse_date s
    | None -> Int64.sub to_ts (Int64.of_int (365 * 86400))
  in
  let label_mode =
    match arg_value "--label-mode" args with
    | Some "threshold" | None -> `Threshold
    | Some "triple-barrier" -> `Triple_barrier
    | Some other ->
        Printf.eprintf "unknown --label-mode: %s (expected threshold|triple-barrier)\n"
          other;
        exit 2
  in
  let horizon =
    match arg_value "--horizon" args with
    | Some v -> int_of_string v
    | None -> 5
  in
  let threshold =
    match arg_value "--threshold" args with
    | Some v -> float_of_string v
    | None -> 0.005
  in
  let tp_mult =
    match arg_value "--tp-mult" args with
    | Some v -> float_of_string v
    | None -> 1.5
  in
  let sl_mult =
    match arg_value "--sl-mult" args with
    | Some v -> float_of_string v
    | None -> 1.0
  in
  let timeout =
    match arg_value "--timeout" args with
    | Some v -> int_of_string v
    | None -> 20
  in
  let prefix = broker_env_prefix broker_id in
  let secret =
    match arg_value "--secret" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_SECRET")
  in
  let account =
    match arg_value "--account" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_ACCOUNT_ID")
  in
  let client_id =
    match arg_value "--client-id" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt "BCS_CLIENT_ID"
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let fetch ~from_ts ~to_ts =
    match broker_id with
    | "finam" -> (
        let secret =
          match secret with
          | Some s -> s
          | None ->
              prerr_endline "finam requires --secret or FINAM_SECRET";
              exit 2
        in
        match open_finam ~env ~secret ~account with
        | Opened_finam { rest; _ } ->
            Finam.Rest.bars rest ~from_ts ~to_ts ~n:9999 ~instrument ~timeframe
        | _ -> assert false)
    | "bcs" -> (
        match open_bcs ~env ~secret ~account ~client_id with
        | Opened_bcs { rest; _ } ->
            Bcs.Rest.bars rest ~from_ts ~to_ts ~n:9999 ~instrument ~timeframe
        | _ -> assert false)
    | other ->
        Printf.eprintf "unknown --broker: %s\n" other;
        exit 2
  in
  let candles = paginate_bars ~fetch ~from_ts ~to_ts in
  Printf.printf "Fetched %d bars from %s (%s)\n%!" (List.length candles) broker_id symbol;
  if candles = [] then exit 0;
  let arr = Array.of_list candles in
  let feats = compute_features arr in
  let written, skipped_warmup, tail_bars =
    match label_mode with
    | `Threshold ->
        let w, s = write_csv_threshold ~path:output ~horizon ~threshold arr feats in
        (w, s, horizon)
    | `Triple_barrier ->
        let w, s =
          write_csv_triple_barrier ~path:output ~tp_mult ~sl_mult ~timeout arr feats
        in
        (w, s, timeout)
  in
  Printf.printf "Wrote %d rows to %s (skipped %d warmup, %d tail bars w/o future)\n%!"
    written output skipped_warmup tail_bars

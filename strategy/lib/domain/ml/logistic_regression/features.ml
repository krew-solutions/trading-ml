(** Feature extraction for the learned composite policy.

    Given N child strategies, produces a float array of 2·N + 2 features:
      [| signal₁; strength₁; signal₂; strength₂; …; volatility; volume_ratio |]

    - [signalᵢ]   = +1.0 (Enter_long), -1.0 (Enter_short/Exit_long/Exit_short), 0.0 (Hold)
    - [strengthᵢ] = Signal.strength (already in [0,1])
    - [volatility] = std(recent_closes) / mean(recent_closes)  (coefficient of variation)
    - [volume_ratio] = current_volume / mean(recent_volumes)

    The two market-context features let the model learn "this
    strategy combination works in low-vol regimes but not high-vol",
    which pure per-strategy Sharpe weighting cannot capture. *)

open Core

let signal_to_float (s : Signal.t) : float =
  match s.action with
  | Enter_long -> 1.0
  | Enter_short | Exit_long | Exit_short -> -1.0
  | Hold -> 0.0

let mean xs =
  match xs with
  | [] -> 0.0
  | _ -> List.fold_left ( +. ) 0.0 xs /. float_of_int (List.length xs)

let std xs =
  let m = mean xs in
  let n = List.length xs in
  if n < 2 then 0.0
  else
    let var =
      List.fold_left (fun acc x -> acc +. ((x -. m) *. (x -. m))) 0.0 xs
      /. float_of_int (n - 1)
    in
    Float.sqrt var

(** Number of features produced for [n_children] child strategies. *)
let n_features ~n_children = (2 * n_children) + 2

(** Extract feature vector from the current bar's child signals and
    recent market data.

    [recent_closes] / [recent_volumes] should contain the last ~20
    bar values (most recent first). If empty, the market-context
    features default to 0.0. *)
let extract
    ~(signals : Signal.t list)
    ~(candle : Candle.t)
    ~(recent_closes : float list)
    ~(recent_volumes : float list) : float array =
  let n = List.length signals in
  let arr = Array.make ((2 * n) + 2) 0.0 in
  List.iteri
    (fun i (s : Signal.t) ->
      arr.(2 * i) <- signal_to_float s;
      arr.((2 * i) + 1) <- s.strength)
    signals;
  let vol_idx = 2 * n in
  let vr_idx = vol_idx + 1 in
  let m_close = mean recent_closes in
  arr.(vol_idx) <-
    (if Float.abs m_close < 1e-9 then 0.0 else std recent_closes /. m_close);
  let m_vol = mean recent_volumes in
  arr.(vr_idx) <-
    (if Float.abs m_vol < 1e-9 then 0.0
     else Decimal.to_float candle.Candle.volume /. m_vol);
  arr

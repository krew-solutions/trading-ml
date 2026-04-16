(** Classic dual-SMA crossover: go long when the fast SMA crosses above the
    slow SMA, exit long (and optionally go short) on the opposite cross.

    Position state is tracked internally so the strategy emits `Enter_long`
    only on the bar where the cross first occurs, not on every bar in the
    trend. *)

open Core

type params = { fast : int; slow : int; allow_short : bool }

type position = Flat | Long | Short

type state = {
  params : params;
  fast : Indicators.Indicator.t;
  slow : Indicators.Indicator.t;
  last_diff : float option;   (* previous fast - slow, for cross detection *)
  position : position;
}

let name = "SMA_Crossover"
let default_params = { fast = 10; slow = 30; allow_short = false }

let init (p : params) =
  if p.fast <= 0 || p.slow <= 0 then invalid_arg "SMA_Crossover: period > 0";
  if p.fast >= p.slow then invalid_arg "SMA_Crossover: fast < slow";
  { params = p;
    fast = Indicators.Sma.make ~period:p.fast;
    slow = Indicators.Sma.make ~period:p.slow;
    last_diff = None;
    position = Flat }

let scalar ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> Some v
  | _ -> None

let on_candle st symbol (c : Candle.t) =
  let fast = Indicators.Indicator.update st.fast c in
  let slow = Indicators.Indicator.update st.slow c in
  let st = { st with fast; slow } in
  match scalar fast, scalar slow with
  | Some f, Some s ->
    let diff = f -. s in
    let action, position, reason =
      match st.last_diff, st.position with
      | Some prev, Flat when prev <= 0.0 && diff > 0.0 ->
        Signal.Enter_long, Long, "fast crossed above slow"
      | Some prev, Long when prev >= 0.0 && diff < 0.0 ->
        if st.params.allow_short
        then Signal.Enter_short, Short, "fast crossed below slow (flip)"
        else Signal.Exit_long, Flat, "fast crossed below slow"
      | Some prev, Short when prev <= 0.0 && diff > 0.0 ->
        Signal.Enter_long, Long, "fast crossed above slow (flip)"
      | _ -> Signal.Hold, st.position, ""
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; symbol; action;
      strength = Float.min 1.0 (Float.abs diff /. (Float.abs s +. 1e-9));
      stop_loss = None; take_profit = None; reason;
    } in
    { st with last_diff = Some diff; position }, sig_
  | _ ->
    st, Signal.hold ~ts:c.Candle.ts ~symbol

(** MACD momentum: enter long on histogram sign flip from -/0 to +,
    exit / reverse on the opposite flip. *)

open Core

type params = {
  fast : int; slow : int; signal : int;
  allow_short : bool;
}

type position = Flat | Long | Short

type state = {
  params : params;
  macd : Indicators.Indicator.t;
  last_hist : float option;
  position : position;
}

let name = "MACD_Momentum"
let default_params = { fast = 12; slow = 26; signal = 9; allow_short = false }

let init p =
  { params = p;
    macd = Indicators.Macd.make ~fast:p.fast ~slow:p.slow ~signal:p.signal ();
    last_hist = None;
    position = Flat }

let hist ind =
  match Indicators.Indicator.value ind with
  | Some (_, [_macd; _signal; h]) -> Some h
  | _ -> None

let on_candle st symbol (c : Candle.t) =
  let macd = Indicators.Indicator.update st.macd c in
  let st = { st with macd } in
  match hist macd with
  | None -> st, Signal.hold ~ts:c.Candle.ts ~symbol
  | Some h ->
    let action, position, reason =
      match st.last_hist, st.position with
      | Some prev, Flat when prev <= 0.0 && h > 0.0 ->
        Signal.Enter_long, Long, "MACD hist crossed above zero"
      | Some prev, Long when prev >= 0.0 && h < 0.0 ->
        if st.params.allow_short
        then Signal.Enter_short, Short, "MACD hist crossed below zero (flip)"
        else Signal.Exit_long, Flat, "MACD hist crossed below zero"
      | Some prev, Short when prev <= 0.0 && h > 0.0 ->
        Signal.Enter_long, Long, "MACD hist crossed above zero (flip)"
      | _ -> Signal.Hold, st.position, ""
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; symbol; action;
      strength = Float.min 1.0 (Float.abs h);
      stop_loss = None; take_profit = None; reason;
    } in
    { st with last_hist = Some h; position }, sig_

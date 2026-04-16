(** Bollinger breakout: go long on close > upper band, go short on
    close < lower band. Exit at middle band. *)

open Core

type params = {
  period : int;
  k : float;
  allow_short : bool;
}

type position = Flat | Long | Short

type state = {
  params : params;
  bb : Indicators.Indicator.t;
  position : position;
}

let name = "Bollinger_Breakout"
let default_params = { period = 20; k = 2.0; allow_short = true }

let init p =
  { params = p;
    bb = Indicators.Bollinger.make ~period:p.period ~k:p.k ();
    position = Flat }

let bands ind =
  match Indicators.Indicator.value ind with
  | Some (_, [l; m; u]) -> Some (l, m, u)
  | _ -> None

let on_candle st symbol (c : Candle.t) =
  let bb = Indicators.Indicator.update st.bb c in
  let st = { st with bb } in
  match bands bb with
  | None -> st, Signal.hold ~ts:c.Candle.ts ~symbol
  | Some (lower, middle, upper) ->
    let close = Core.Decimal.to_float c.Candle.close in
    let action, position, reason =
      match st.position with
      | Flat when close > upper ->
        Signal.Enter_long, Long, "close above upper band"
      | Flat when st.params.allow_short && close < lower ->
        Signal.Enter_short, Short, "close below lower band"
      | Long when close < middle ->
        Signal.Exit_long, Flat, "close reverted to middle"
      | Short when close > middle ->
        Signal.Exit_short, Flat, "close reverted to middle"
      | _ -> Signal.Hold, st.position, ""
    in
    let width = upper -. lower in
    let strength =
      if width <= 0.0 then 0.0
      else Float.min 1.0 (Float.abs (close -. middle) /. (width /. 2.0))
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; symbol; action; strength;
      stop_loss = None; take_profit = None; reason;
    } in
    { st with position }, sig_

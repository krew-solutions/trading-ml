(** RSI mean reversion: enter long when RSI < lower threshold (oversold),
    exit when RSI > exit_long threshold. Short side mirrors. *)

open Core

type params = {
  period : int;
  lower : float;
  upper : float;
  exit_long : float;
  exit_short : float;
  allow_short : bool;
}

type position = Flat | Long | Short

type state = {
  params : params;
  rsi : Indicators.Indicator.t;
  position : position;
}

let name = "RSI_MeanReversion"

let default_params = {
  period = 14;
  lower = 30.0;
  upper = 70.0;
  exit_long = 50.0;
  exit_short = 50.0;
  allow_short = false;
}

let init p =
  if p.lower >= p.upper then invalid_arg "RSI_MR: lower >= upper";
  { params = p; rsi = Indicators.Rsi.make ~period:p.period; position = Flat }

let scalar ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> Some v
  | _ -> None

let on_candle st symbol (c : Candle.t) =
  let rsi = Indicators.Indicator.update st.rsi c in
  let st = { st with rsi } in
  match scalar rsi with
  | None -> st, Signal.hold ~ts:c.Candle.ts ~symbol
  | Some v ->
    let p = st.params in
    let action, position, reason =
      match st.position with
      | Flat when v < p.lower ->
        Signal.Enter_long, Long,
        Printf.sprintf "RSI %.2f < %.2f" v p.lower
      | Flat when p.allow_short && v > p.upper ->
        Signal.Enter_short, Short,
        Printf.sprintf "RSI %.2f > %.2f" v p.upper
      | Long when v > p.exit_long ->
        Signal.Exit_long, Flat, Printf.sprintf "RSI %.2f > exit" v
      | Short when v < p.exit_short ->
        Signal.Exit_short, Flat, Printf.sprintf "RSI %.2f < exit" v
      | _ -> Signal.Hold, st.position, ""
    in
    let strength =
      match action with
      | Signal.Enter_long ->
        Float.min 1.0 ((p.lower -. v) /. p.lower)
      | Enter_short ->
        Float.min 1.0 ((v -. p.upper) /. (100.0 -. p.upper +. 1e-9))
      | _ -> 0.0
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; symbol; action;
      strength; stop_loss = None; take_profit = None; reason;
    } in
    { st with position }, sig_

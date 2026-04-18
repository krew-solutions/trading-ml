open Core

type params = { fast : int; slow : int; allow_short : bool }

type position = Flat | Long | Short

type state = {
  params : params;
  osc : Indicators.Indicator.t;
  last_v : float option;
  position : position;
}

let name = "Chaikin_Momentum"
let default_params = { fast = 3; slow = 10; allow_short = false }

let init p =
  if p.fast <= 0 || p.slow <= 0 then
    invalid_arg "Chaikin_Momentum: periods > 0";
  if p.fast >= p.slow then
    invalid_arg "Chaikin_Momentum: fast < slow";
  { params = p;
    osc = Indicators.Chaikin_oscillator.make ~fast:p.fast ~slow:p.slow ();
    last_v = None;
    position = Flat }

let scalar ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> Some v
  | _ -> None

let on_candle st instrument (c : Candle.t) =
  let osc = Indicators.Indicator.update st.osc c in
  let st = { st with osc } in
  match scalar osc with
  | None -> st, Signal.hold ~ts:c.Candle.ts ~instrument
  | Some v ->
    let action, position, reason =
      match st.last_v, st.position with
      | Some prev, Flat when prev <= 0.0 && v > 0.0 ->
        Signal.Enter_long, Long, "Chaikin osc crossed above zero"
      | Some prev, Long when prev >= 0.0 && v < 0.0 ->
        if st.params.allow_short
        then Signal.Enter_short, Short, "Chaikin osc crossed below zero (flip)"
        else Signal.Exit_long, Flat, "Chaikin osc crossed below zero"
      | Some prev, Short when prev <= 0.0 && v > 0.0 ->
        Signal.Enter_long, Long, "Chaikin osc crossed above zero (flip)"
      | _ -> Signal.Hold, st.position, ""
    in
    let sig_ = {
      Signal.ts = c.Candle.ts; instrument; action;
      (* Chaikin oscillator values can be large — normalize by
         absolute value for strength. The 1e6 floor is a pragmatic
         scale hint so small-cap oscillations don't produce 1.0. *)
      strength = Float.min 1.0 (Float.abs v /. 1e6);
      stop_loss = None; take_profit = None; reason;
    } in
    { st with last_v = Some v; position }, sig_

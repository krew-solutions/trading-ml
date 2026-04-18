open Core

type params = { period : int; allow_short : bool }

type position = Flat | Long | Short

type state = {
  params : params;
  ad : Indicators.Indicator.t;
  ring : float Indicators.Ring.t;
  sum : float;
  last_diff : float option;
  position : position;
}

let name = "AD_MA_Crossover"
let default_params = { period = 20; allow_short = false }

let init p =
  if p.period <= 0 then invalid_arg "AD_MA_Crossover: period > 0";
  { params = p;
    ad = Indicators.Ad.make ();
    ring = Indicators.Ring.create ~capacity:p.period 0.0;
    sum = 0.0;
    last_diff = None;
    position = Flat }

let scalar ind =
  match Indicators.Indicator.value ind with
  | Some (_, [v]) -> Some v
  | _ -> None

let roll ring sum x =
  let ring' = Indicators.Ring.copy ring in
  let sum' =
    if Indicators.Ring.is_full ring
    then sum -. Indicators.Ring.oldest ring +. x
    else sum +. x
  in
  Indicators.Ring.push ring' x;
  ring', sum'

let on_candle st instrument (c : Candle.t) =
  let ad = Indicators.Indicator.update st.ad c in
  match scalar ad with
  | None -> { st with ad }, Signal.hold ~ts:c.Candle.ts ~instrument
  | Some v ->
    let ring, sum = roll st.ring st.sum v in
    let st = { st with ad; ring; sum } in
    if not (Indicators.Ring.is_full ring) then
      st, Signal.hold ~ts:c.Candle.ts ~instrument
    else
      let avg = sum /. float_of_int st.params.period in
      let diff = v -. avg in
      let action, position, reason =
        match st.last_diff, st.position with
        | Some prev, Flat when prev <= 0.0 && diff > 0.0 ->
          Signal.Enter_long, Long, "A/D crossed above SMA(A/D)"
        | Some prev, Long when prev >= 0.0 && diff < 0.0 ->
          if st.params.allow_short
          then Signal.Enter_short, Short, "A/D crossed below SMA(A/D) (flip)"
          else Signal.Exit_long, Flat, "A/D crossed below SMA(A/D)"
        | Some prev, Short when prev <= 0.0 && diff > 0.0 ->
          Signal.Enter_long, Long, "A/D crossed above SMA(A/D) (flip)"
        | _ -> Signal.Hold, st.position, ""
      in
      let sig_ = {
        Signal.ts = c.Candle.ts; instrument; action;
        strength = Float.min 1.0 (Float.abs diff /. (Float.abs avg +. 1e-9));
        stop_loss = None; take_profit = None; reason;
      } in
      { st with last_diff = Some diff; position }, sig_

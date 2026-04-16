(** Chaikin Volatility Indicator.
    spread_t = EMA(high - low, period)
    CVI_t    = 100 · (spread_t - spread_{t-period}) / spread_{t-period}
    Streams candles through an inline EMA of the high-low range and stores
    the last [period] spreads in a ring to produce the percent change. *)

open Core

module Make (C : sig val period : int end) : Indicator.S = struct
  let () = if C.period <= 0 then invalid_arg "CVI: period must be > 0"

  type state = {
    ema_samples : int;
    ema_seed : float;
    ema_value : float option;
    history : float Ring.t;
  }
  type output = float

  let name = Printf.sprintf "CVI(%d)" C.period
  let alpha = 2.0 /. (float_of_int C.period +. 1.0)

  let init () = {
    ema_samples = 0; ema_seed = 0.0; ema_value = None;
    (* period+1 slots: we need spread_t and spread_{t-period}. *)
    history = Ring.create ~capacity:(C.period + 1) 0.0;
  }

  let step_ema st x =
    if st.ema_samples < C.period - 1 then
      { st with ema_samples = st.ema_samples + 1;
                ema_seed = st.ema_seed +. x }
    else if st.ema_samples = C.period - 1 then
      let s = st.ema_seed +. x in
      { st with ema_samples = st.ema_samples + 1;
                ema_seed = s;
                ema_value = Some (s /. float_of_int C.period) }
    else
      let v = match st.ema_value with Some v -> v | None -> x in
      { st with ema_value = Some (alpha *. x +. (1.0 -. alpha) *. v) }

  let update st c =
    let range =
      Decimal.to_float c.Candle.high -. Decimal.to_float c.low in
    let st' = step_ema st range in
    let h = Ring.copy st'.history in
    (match st'.ema_value with
     | Some v -> Ring.push h v
     | None -> ());
    let st'' = { st' with history = h } in
    let out =
      if Ring.size h = C.period + 1 then
        let prev = Ring.oldest h in
        let curr = Ring.newest h in
        if prev = 0.0 then None
        else Some (100.0 *. (curr -. prev) /. prev)
      else None
    in
    st'', out

  let value st =
    if Ring.size st.history = C.period + 1 then
      let prev = Ring.oldest st.history in
      let curr = Ring.newest st.history in
      if prev = 0.0 then None
      else Some (100.0 *. (curr -. prev) /. prev)
    else None

  let output_to_float x = [x]
end

let make ~period =
  let module Mk = Make (struct let period = period end) in
  Indicator.make (module Mk)

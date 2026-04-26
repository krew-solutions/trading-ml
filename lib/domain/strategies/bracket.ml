open Core

type params = {
  tp_mult : float;
  sl_mult : float;
  max_hold_bars : int;
  atr_period : int;
  inner : Strategy.t;
}

type bracket_state = { tp : float; sl : float; bars_held : int }
(** Active-position bookkeeping. [bars_held] counts bars since
    entry so the timeout barrier can fire without reading
    wall-clock time; [tp] and [sl] are the absolute price
    levels, computed once at entry from [close ± mult·ATR]. *)

type position = Flat | Long of bracket_state | Short of bracket_state

type state = {
  params : params;
  atr : Indicators.Indicator.t;
  inner : Strategy.t;
  position : position;
}

let name = "Bracket"

(** Default [inner] is a placeholder — the registry always supplies
    a real wrapped strategy via [build], and a standalone
    [default_params] call is not expected to produce a usable
    decorator on its own. Same convention as
    {!Composite.default_params}, whose [children = []] is
    similarly a placeholder. *)
let default_params =
  {
    tp_mult = 1.5;
    sl_mult = 1.0;
    max_hold_bars = 20;
    atr_period = 14;
    inner = Strategy.default (module Sma_crossover);
  }

let init p =
  if p.tp_mult <= 0.0 then invalid_arg "Bracket: tp_mult > 0";
  if p.sl_mult <= 0.0 then invalid_arg "Bracket: sl_mult > 0";
  if p.max_hold_bars <= 0 then invalid_arg "Bracket: max_hold_bars > 0";
  if p.atr_period <= 1 then invalid_arg "Bracket: atr_period > 1";
  {
    params = p;
    atr = Indicators.Atr.make ~period:p.atr_period;
    inner = p.inner;
    position = Flat;
  }

let scalar_atr ind =
  match Indicators.Indicator.value ind with
  | Some (_, [ v ]) -> Some v
  | _ -> None

(** Bracket-exit probe for a long position. SL is checked before
    TP so a bar whose range crosses both barriers resolves to SL
    — the conservative side (we don't know intra-bar path), and
    the convention that matches {!Ml.Triple_barrier.label}. *)
let check_long_exit ~high ~low bs =
  if low <= bs.sl then Some "SL hit" else if high >= bs.tp then Some "TP hit" else None

let check_short_exit ~high ~low bs =
  if high >= bs.sl then Some "SL hit" else if low <= bs.tp then Some "TP hit" else None

let on_candle st instrument (c : Candle.t) =
  let close = Decimal.to_float c.Candle.close in
  let high = Decimal.to_float c.Candle.high in
  let low = Decimal.to_float c.Candle.low in
  (* Always advance ATR and the inner strategy, regardless of
     current position. Skipping either would leave them stale
     when we return to Flat and need fresh state. *)
  let atr = Indicators.Indicator.update st.atr c in
  let inner, inner_sig = Strategy.on_candle st.inner instrument c in
  let st = { st with atr; inner } in
  match st.position with
  | Long bs -> (
      let bars_held = bs.bars_held + 1 in
      let exit_reason =
        match check_long_exit ~high ~low bs with
        | Some r -> Some r
        | None -> if bars_held >= st.params.max_hold_bars then Some "timeout" else None
      in
      match exit_reason with
      | Some reason ->
          let sig_ =
            {
              Signal.ts = c.Candle.ts;
              instrument;
              action = Signal.Exit_long;
              strength = 1.0;
              stop_loss = None;
              take_profit = None;
              reason;
            }
          in
          ({ st with position = Flat }, sig_)
      | None ->
          ( { st with position = Long { bs with bars_held } },
            Signal.hold ~ts:c.Candle.ts ~instrument ))
  | Short bs -> (
      let bars_held = bs.bars_held + 1 in
      let exit_reason =
        match check_short_exit ~high ~low bs with
        | Some r -> Some r
        | None -> if bars_held >= st.params.max_hold_bars then Some "timeout" else None
      in
      match exit_reason with
      | Some reason ->
          let sig_ =
            {
              Signal.ts = c.Candle.ts;
              instrument;
              action = Signal.Exit_short;
              strength = 1.0;
              stop_loss = None;
              take_profit = None;
              reason;
            }
          in
          ({ st with position = Flat }, sig_)
      | None ->
          ( { st with position = Short { bs with bars_held } },
            Signal.hold ~ts:c.Candle.ts ~instrument ))
  | Flat -> (
      (* Propagate inner's signal, enriching entries with concrete
       TP/SL levels derived from current ATR. During ATR warm-up
       we swallow entries rather than firing blind ones — a
       naked entry with [stop_loss = None] would propagate to
       the broker and the trade would run without protection,
       which is exactly the failure mode brackets exist to
       prevent. *)
      match (inner_sig.Signal.action, scalar_atr atr) with
      | Signal.Enter_long, Some a ->
          let tp = close +. (st.params.tp_mult *. a) in
          let sl = close -. (st.params.sl_mult *. a) in
          let sig_ =
            {
              inner_sig with
              stop_loss = Some (Decimal.of_float sl);
              take_profit = Some (Decimal.of_float tp);
            }
          in
          let pos = Long { tp; sl; bars_held = 0 } in
          ({ st with position = pos }, sig_)
      | Signal.Enter_short, Some a ->
          let tp = close -. (st.params.tp_mult *. a) in
          let sl = close +. (st.params.sl_mult *. a) in
          let sig_ =
            {
              inner_sig with
              stop_loss = Some (Decimal.of_float sl);
              take_profit = Some (Decimal.of_float tp);
            }
          in
          let pos = Short { tp; sl; bars_held = 0 } in
          ({ st with position = pos }, sig_)
      | (Signal.Enter_long | Signal.Enter_short), None ->
          (* ATR still warming up — decline the entry. *)
          (st, Signal.hold ~ts:c.Candle.ts ~instrument)
      | _ ->
          (* Hold, Exit_*, anything else: pass through unchanged. *)
          (st, inner_sig))

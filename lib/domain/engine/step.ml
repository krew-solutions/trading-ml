open Core

type config = {
  limits : Risk.limits;
  instrument : Instrument.t;
  fee_rate : float;
}

type settled = {
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
}

type state = {
  strat : Strategies.Strategy.t;
  portfolio : Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
}

let make_state ~strategy ~cash = {
  strat = strategy;
  portfolio = Portfolio.empty ~cash;
  pending_signal = None;
  last_bar_ts = 0L;
}

let size_for_signal ~config ~portfolio ~price (sig_ : Signal.t)
  : (Side.t * Decimal.t) option =
  let mark _ = Some price in
  let equity = Portfolio.equity portfolio mark in
  let entry_qty side =
    let q = Risk.size_from_strength
      ~equity ~price ~limits:config.limits
      ~strength:(Float.max 0.1 sig_.strength) in
    if Decimal.is_zero q then None else Some (side, q)
  in
  match sig_.action with
  | Signal.Hold -> None
  | Enter_long  -> entry_qty Side.Buy
  | Enter_short -> entry_qty Side.Sell
  | Exit_long ->
    (match Portfolio.position portfolio config.instrument with
     | Some p when Decimal.is_positive p.quantity ->
       Some (Side.Sell, Decimal.abs p.quantity)
     | _ -> None)
  | Exit_short ->
    (match Portfolio.position portfolio config.instrument with
     | Some p when Decimal.is_negative p.quantity ->
       Some (Side.Buy, Decimal.abs p.quantity)
     | _ -> None)

let execute_pending config state (c : Candle.t)
  : state * (Signal.t * settled) option =
  match state.pending_signal with
  | None -> state, None
  | Some sig_ ->
    let price = c.Candle.open_ in
    let mark _ = Some price in
    let cleared = { state with pending_signal = None } in
    match size_for_signal ~config ~portfolio:state.portfolio ~price sig_ with
    | None -> cleared, None
    | Some (side, qty) ->
      match Risk.check ~portfolio:state.portfolio ~limits:config.limits
              ~instrument:config.instrument ~side
              ~quantity:qty ~price ~mark with
      | Reject _ -> cleared, None
      | Accept q ->
        let fee = Decimal.mul
          (Decimal.mul q price) (Decimal.of_float config.fee_rate) in
        let portfolio' = Portfolio.fill state.portfolio
          ~instrument:config.instrument ~side
          ~quantity:q ~price ~fee in
        { cleared with portfolio = portfolio' },
        Some (sig_, { side; quantity = q; price; fee })

let advance_strategy config state (c : Candle.t) : state =
  let strat', sig_ = Strategies.Strategy.on_candle
    state.strat config.instrument c in
  let pending =
    if sig_.Signal.action = Signal.Hold then None else Some sig_ in
  { state with
    strat = strat';
    pending_signal = pending;
    last_bar_ts = c.ts }

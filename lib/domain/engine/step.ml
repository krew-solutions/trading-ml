open Core

type config = {
  limits : Risk.limits;
  instrument : Instrument.t;
  fee_rate : float;
  auto_commit : bool;
}

type settled = {
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reservation_id : int;
}

type state = {
  strat : Strategies.Strategy.t;
  portfolio : Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
  reservation_seq : int;
}

let make_state ~strategy ~cash = {
  strat = strategy;
  portfolio = Portfolio.empty ~cash;
  pending_signal = None;
  last_bar_ts = Int64.min_int;
  reservation_seq = 0;
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
        let reservation_id = state.reservation_seq in
        let portfolio_r = Portfolio.reserve state.portfolio
          ~id:reservation_id ~side ~instrument:config.instrument
          ~quantity:q ~price
          ~slippage_buffer:0.0
          ~fee_rate:config.fee_rate in
        (* [auto_commit]: Backtest commits immediately (no broker
           latency); Live leaves the reservation open until a fill
           event arrives and calls {!commit_fill} externally. *)
        let portfolio' =
          if config.auto_commit then
            Portfolio.commit_fill portfolio_r
              ~id:reservation_id
              ~actual_quantity:q ~actual_price:price ~actual_fee:fee
          else
            portfolio_r
        in
        { cleared with
          portfolio = portfolio';
          reservation_seq = reservation_id + 1; },
        Some (sig_, { side; quantity = q; price; fee; reservation_id })

let commit_fill state ~reservation_id
    ~actual_quantity ~actual_price ~actual_fee =
  let portfolio' = Portfolio.commit_fill state.portfolio
    ~id:reservation_id
    ~actual_quantity ~actual_price ~actual_fee in
  { state with portfolio = portfolio' }

let release state ~reservation_id =
  let portfolio' = Portfolio.release state.portfolio ~id:reservation_id in
  { state with portfolio = portfolio' }

let advance_strategy config state (c : Candle.t) : state =
  let strat', sig_ = Strategies.Strategy.on_candle
    state.strat config.instrument c in
  let pending =
    if sig_.Signal.action = Signal.Hold then None else Some sig_ in
  { state with
    strat = strat';
    pending_signal = pending;
    last_bar_ts = c.ts }

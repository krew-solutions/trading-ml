open Core

type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
  fee_rate : float;
}

(** State mirrors {!Engine.Backtest}'s recursion parameters:
    - [strat]    : advancing strategy snapshot (indicator windows etc.)
    - [portfolio]: cash + positions + realized PnL
    - [pending_signal] : signal queued on bar T, executed at [open T+1]
    - [last_bar_ts]    : monotonicity guard for duplicate bar feeds
    - [seq]     : monotone counter for unique client_order_id
    - [placed]  : submitted orders, newest first *)
type state = {
  strat : Strategies.Strategy.t;
  portfolio : Engine.Portfolio.t;
  pending_signal : Signal.t option;
  last_bar_ts : int64;
  seq : int;
  placed : Order.t list;
}

type t = {
  cfg : config;
  mutable state : state;
  mutex : Mutex.t;
}

let make (cfg : config) : t = {
  cfg;
  state = {
    strat = cfg.strategy;
    portfolio = Engine.Portfolio.empty ~cash:cfg.initial_cash;
    pending_signal = None;
    last_bar_ts = 0L;
    seq = 0;
    placed = [];
  };
  mutex = Mutex.create ();
}

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let next_cid ~broker_name ~strat_name ~seq =
  Printf.sprintf "eng-%s-%s-%d-%d"
    broker_name strat_name
    (int_of_float (Unix.gettimeofday ()))
    seq

(** Pure: figure out [(side, quantity)] for a pending signal, marked
    at [price]. Mirrors {!Engine.Backtest.apply_signal}'s sizing.
    Returns [None] for Hold or inapplicable exits (e.g. Exit_long
    when flat). *)
let size_for_signal ~(config : config) ~(portfolio : Engine.Portfolio.t)
    ~(price : Decimal.t) (sig_ : Signal.t)
  : (Side.t * Decimal.t) option =
  let mark _ = Some price in
  let equity = Engine.Portfolio.equity portfolio mark in
  let entry_qty side =
    let q = Engine.Risk.size_from_strength
      ~equity ~price ~limits:config.limits
      ~strength:(Float.max 0.1 sig_.strength) in
    if Decimal.is_zero q then None else Some (side, q)
  in
  match sig_.action with
  | Signal.Hold -> None
  | Enter_long  -> entry_qty Side.Buy
  | Enter_short -> entry_qty Side.Sell
  | Exit_long ->
    (match Engine.Portfolio.position portfolio config.instrument with
     | Some p when Decimal.is_positive p.quantity ->
       Some (Side.Sell, Decimal.abs p.quantity)
     | _ -> None)
  | Exit_short ->
    (match Engine.Portfolio.position portfolio config.instrument with
     | Some p when Decimal.is_negative p.quantity ->
       Some (Side.Buy, Decimal.abs p.quantity)
     | _ -> None)

(** Execute any pending signal at the opening of [c]. Mirrors the
    first step of {!Engine.Backtest}'s main loop: size at
    [c.open_], risk-check, synthesize a portfolio fill, and
    submit the order to the broker. Broker IO is best-effort —
    exceptions are logged but do not unwind the synthetic fill, so
    the engine's ledger stays consistent regardless of broker
    availability (reconciliation is a separate concern). *)
let execute_pending ~(config : config) (state : state) (c : Candle.t)
  : state =
  match state.pending_signal with
  | None -> state
  | Some sig_ ->
    let price = c.Candle.open_ in
    let mark _ = Some price in
    match size_for_signal ~config ~portfolio:state.portfolio ~price sig_ with
    | None -> state
    | Some (side, qty) ->
      match Engine.Risk.check
              ~portfolio:state.portfolio ~limits:config.limits
              ~instrument:config.instrument ~side
              ~quantity:qty ~price ~mark with
      | Reject reason ->
        Log.warn "[engine] risk gate rejected %s: %s"
          (Side.to_string side) reason;
        state
      | Accept q ->
        let fee = Decimal.mul
          (Decimal.mul q price) (Decimal.of_float config.fee_rate) in
        let portfolio' = Engine.Portfolio.fill state.portfolio
          ~instrument:config.instrument ~side ~quantity:q ~price ~fee in
        let cid = next_cid
          ~broker_name:(Broker.name config.broker)
          ~strat_name:(Strategies.Strategy.name state.strat)
          ~seq:state.seq in
        let placed' =
          try
            let o = Broker.place_order config.broker
              ~instrument:config.instrument
              ~side ~quantity:q
              ~kind:Order.Market ~tif:config.tif
              ~client_order_id:cid in
            Log.info "[engine] %s %s qty=%s cid=%s status=%s"
              (Strategies.Strategy.name state.strat)
              (Side.to_string side) (Decimal.to_string q)
              cid (Order.status_to_string o.status);
            o :: state.placed
          with e ->
            Log.warn "[engine] place_order failed (cid=%s): %s"
              cid (Printexc.to_string e);
            state.placed
        in
        { state with
          portfolio = portfolio';
          seq = state.seq + 1;
          placed = placed';
        }

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
    if Int64.compare c.ts t.state.last_bar_ts <= 0 then ()
    else begin
      let s1 = execute_pending ~config:t.cfg t.state c in
      let strat', sig_ = Strategies.Strategy.on_candle
        s1.strat t.cfg.instrument c in
      let pending =
        if sig_.Signal.action = Signal.Hold then None else Some sig_
      in
      t.state <- { s1 with
        strat = strat';
        pending_signal = pending;
        last_bar_ts = c.ts;
      }
    end)

let position t = with_lock t (fun () ->
  match Engine.Portfolio.position t.state.portfolio t.cfg.instrument with
  | Some p -> p.quantity
  | None -> Decimal.zero)

let portfolio t = with_lock t (fun () -> t.state.portfolio)

let placed t = with_lock t (fun () -> List.rev t.state.placed)

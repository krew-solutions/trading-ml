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

(** Live state = {!Engine.Step.state} (shared with Backtest) plus
    live-specific bookkeeping: a seq counter for unique
    [client_order_id]s and the list of submitted orders for the UI. *)
type t = {
  cfg : config;
  step_cfg : Engine.Step.config;
  mutable state : Engine.Step.state;
  mutable seq : int;
  mutable placed : Order.t list;    (** newest first *)
  mutex : Mutex.t;
}

let make (cfg : config) : t =
  let step_cfg : Engine.Step.config = {
    limits = cfg.limits;
    instrument = cfg.instrument;
    fee_rate = cfg.fee_rate;
  } in
  {
    cfg;
    step_cfg;
    state = Engine.Step.make_state
      ~strategy:cfg.strategy ~cash:cfg.initial_cash;
    seq = 0;
    placed = [];
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

let submit_order t ~(strat_name : string) (settled : Engine.Step.settled) =
  let cid = next_cid
    ~broker_name:(Broker.name t.cfg.broker)
    ~strat_name
    ~seq:t.seq in
  t.seq <- t.seq + 1;
  try
    let o = Broker.place_order t.cfg.broker
      ~instrument:t.cfg.instrument
      ~side:settled.side ~quantity:settled.quantity
      ~kind:Order.Market ~tif:t.cfg.tif
      ~client_order_id:cid in
    t.placed <- o :: t.placed;
    Log.info "[engine] %s %s qty=%s cid=%s status=%s"
      strat_name (Side.to_string settled.side)
      (Decimal.to_string settled.quantity)
      cid (Order.status_to_string o.status)
  with e ->
    Log.warn "[engine] place_order failed (cid=%s): %s"
      cid (Printexc.to_string e)

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
    if Int64.compare c.ts t.state.last_bar_ts <= 0 then ()
    else begin
      let strat_name = Strategies.Strategy.name t.state.strat in
      let state1, fill_opt = Engine.Step.execute_pending
        t.step_cfg t.state c in
      (match fill_opt with
       | Some (_sig, settled) -> submit_order t ~strat_name settled
       | None -> ());
      let state2 = Engine.Step.advance_strategy t.step_cfg state1 c in
      t.state <- state2
    end)

let position t = with_lock t (fun () ->
  match Engine.Portfolio.position t.state.portfolio t.cfg.instrument with
  | Some p -> p.quantity
  | None -> Decimal.zero)

let portfolio t = with_lock t (fun () -> t.state.portfolio)

let placed t = with_lock t (fun () -> List.rev t.placed)

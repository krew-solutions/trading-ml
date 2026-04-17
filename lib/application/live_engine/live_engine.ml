open Core

type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
}

type t = {
  cfg : config;
  mutable strat : Strategies.Strategy.t;
  mutable position : Decimal.t;     (** running net qty: + long, - short *)
  mutable last_bar_ts : int64;
  mutable seq : int;                (** client_order_id sequence *)
  mutable placed : Order.t list;    (** newest first *)
  mutex : Mutex.t;
}

let make (cfg : config) : t = {
  cfg;
  strat = cfg.strategy;
  position = Decimal.zero;
  last_bar_ts = 0L;
  seq = 0;
  placed = [];
  mutex = Mutex.create ();
}

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

(** Client order id format: [eng-<broker>-<strat>-<unix_ts>-<seq>].
    Human-readable for logs; unique under the engine's own mutex;
    stable across broker restarts (seq resets, ts monotonic). *)
let next_client_order_id t =
  let s = t.seq in
  t.seq <- s + 1;
  Printf.sprintf "eng-%s-%s-%d-%d"
    (Broker.name t.cfg.broker)
    (Strategies.Strategy.name t.strat)
    (int_of_float (Unix.gettimeofday ()))
    s

(** Translate a strategy Signal into a market order intent. Returns
    [None] for [Hold] or when the entry/exit is a no-op (e.g.
    Exit_long with no long position held). Entry sizing goes through
    [Risk.size_from_strength]; exits size to the current position
    (we close what we own, no more, no less). *)
let signal_to_intent t (c : Candle.t) (sig_ : Signal.t)
  : (Side.t * Decimal.t) option =
  let price = c.Candle.close in
  let equity =
    (* Approximate: initial cash plus position marked at current
       close. Good enough for sizing; the broker / Risk gate does
       the real bookkeeping. *)
    Decimal.add t.cfg.initial_cash
      (Decimal.mul t.position price)
  in
  let entry_qty side =
    let q = Engine.Risk.size_from_strength
      ~equity ~price ~limits:t.cfg.limits
      ~strength:(Float.max 0.1 sig_.strength)
    in
    if Decimal.is_zero q then None else Some (side, q)
  in
  match sig_.action with
  | Signal.Hold -> None
  | Enter_long  -> entry_qty Side.Buy
  | Enter_short -> entry_qty Side.Sell
  | Exit_long ->
    if Decimal.is_positive t.position
    then Some (Side.Sell, Decimal.abs t.position)
    else None
  | Exit_short ->
    if Decimal.is_negative t.position
    then Some (Side.Buy, Decimal.abs t.position)
    else None

let apply_intent t (side, qty) =
  let cid = next_client_order_id t in
  try
    let o = Broker.place_order t.cfg.broker
      ~instrument:t.cfg.instrument
      ~side ~quantity:qty
      ~kind:Order.Market
      ~tif:t.cfg.tif
      ~client_order_id:cid
    in
    t.placed <- o :: t.placed;
    (match side with
     | Side.Buy  -> t.position <- Decimal.add t.position qty
     | Side.Sell -> t.position <- Decimal.sub t.position qty);
    Log.info "[engine] %s %s qty=%s cid=%s status=%s"
      (Strategies.Strategy.name t.strat)
      (match side with Side.Buy -> "BUY" | Side.Sell -> "SELL")
      (Decimal.to_string qty) cid
      (Order.status_to_string o.status)
  with e ->
    Log.warn "[engine] place_order failed (cid=%s): %s"
      cid (Printexc.to_string e)

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
    if Int64.compare c.ts t.last_bar_ts <= 0 then ()
    else begin
      t.last_bar_ts <- c.ts;
      let strat', sig_ = Strategies.Strategy.on_candle
        t.strat t.cfg.instrument c in
      t.strat <- strat';
      match signal_to_intent t c sig_ with
      | None -> ()
      | Some intent -> apply_intent t intent
    end)

let position t = with_lock t (fun () -> t.position)
let placed t = with_lock t (fun () -> List.rev t.placed)

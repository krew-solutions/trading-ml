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
type pending = {
  reservation_id : int;
  intended_quantity : Decimal.t;
  intended_price : Decimal.t;
  intended_fee : Decimal.t;
  (** Snapshot of the numbers Step reserved against — used by
      {!reconcile} when the broker reports [Filled] without a
      granular WS event that would carry the actual fill price. *)
}

type t = {
  cfg : config;
  step_cfg : Engine.Step.config;
  mutable state : Engine.Step.state;
  mutable seq : int;
  mutable placed : Order.t list;    (** newest first *)
  pending : (string, pending) Hashtbl.t;
  (** [client_order_id → pending] for orders we've submitted to the
      broker and are waiting to confirm. Populated at [submit_order];
      consumed by {!on_fill_event} (actual numbers) or
      {!reconcile} (intended numbers as fallback). *)
  mutex : Mutex.t;
}

let make (cfg : config) : t =
  let step_cfg : Engine.Step.config = {
    limits = cfg.limits;
    instrument = cfg.instrument;
    fee_rate = cfg.fee_rate;
    auto_commit = false;
    (* Live defers commit until the broker reports a fill via
       {!on_fill_event}. Reservations stay open until then and
       properly shrink [available_cash] for subsequent Risk gates. *)
  } in
  {
    cfg;
    step_cfg;
    state = Engine.Step.make_state
      ~strategy:cfg.strategy ~cash:cfg.initial_cash;
    seq = 0;
    placed = [];
    pending = Hashtbl.create 16;
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
  (* Record [cid → pending] BEFORE the broker call so we're ready
     for an instant fill event (Paper's listener fires synchronously
     during place_order evaluation on the next bar). *)
  Hashtbl.replace t.pending cid {
    reservation_id = settled.reservation_id;
    intended_quantity = settled.quantity;
    intended_price = settled.price;
    intended_fee = settled.fee;
  };
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
      cid (Printexc.to_string e);
    Hashtbl.remove t.pending cid;
    t.state <- Engine.Step.release t.state
      ~reservation_id:settled.reservation_id

(** Fold a {!Pipeline.event} into the mutable wrapper: update the
    state snapshot for external queries, submit any settled trade to
    the broker. Called under the mutex. *)
let apply_event t (event : Engine.Pipeline.event) =
  let strat_name = Strategies.Strategy.name t.state.strat in
  t.state <- event.state;
  match event.settled with
  | Some (_sig, settled) -> submit_order t ~strat_name settled
  | None -> ()

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
    (* One-bar driver: feed a singleton stream through the same
       Pipeline.run that Live's streaming [run] and Backtest use. Out-
       of-order bars are filtered inside Pipeline, not here. *)
    Stream.of_list [c]
    |> Engine.Pipeline.run t.step_cfg t.state
    |> Stream.iter (apply_event t))

let run t ~source =
  (* Stream driver: WS bridge pushes candles into [source], pipeline
     threads state internally, we mirror each event into [t.state] and
     route settled trades to the broker. Exactly the same
     [Pipeline.run] that Backtest consumes via [to_list + aggregate] —
     divergence in behaviour is impossible by construction. *)
  Eio_stream.of_eio_stream source
  |> Engine.Pipeline.run t.step_cfg t.state
  |> Stream.iter (fun event ->
    with_lock t (fun () -> apply_event t event))

type fill_event = {
  client_order_id : string;
  actual_quantity : Decimal.t;
  actual_price : Decimal.t;
  actual_fee : Decimal.t;
}

let on_fill_event t (fe : fill_event) =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.pending fe.client_order_id with
    | None ->
      Log.warn "[engine] fill_event for unknown cid=%s (ignored)"
        fe.client_order_id
    | Some p ->
      Hashtbl.remove t.pending fe.client_order_id;
      t.state <- Engine.Step.commit_fill t.state
        ~reservation_id:p.reservation_id
        ~actual_quantity:fe.actual_quantity
        ~actual_price:fe.actual_price
        ~actual_fee:fe.actual_fee;
      Log.info "[engine] commit cid=%s qty=%s @ %s"
        fe.client_order_id
        (Decimal.to_string fe.actual_quantity)
        (Decimal.to_string fe.actual_price))

(** Check broker state and settle reservations that have reached
    terminal status. Paper's in-process callback normally handles
    this first; reconcile catches anything the callback missed
    (network drops, WS reconnects, broker restart). *)
let reconcile t =
  with_lock t (fun () ->
    let orders = try Broker.get_orders t.cfg.broker with e ->
      Log.warn "[engine] reconcile: get_orders failed: %s"
        (Printexc.to_string e); []
    in
    List.iter (fun (o : Order.t) ->
      match Hashtbl.find_opt t.pending o.client_order_id with
      | None -> ()
      | Some p ->
        match o.status with
        | Filled ->
          Hashtbl.remove t.pending o.client_order_id;
          t.state <- Engine.Step.commit_fill t.state
            ~reservation_id:p.reservation_id
            ~actual_quantity:p.intended_quantity
            ~actual_price:p.intended_price
            ~actual_fee:p.intended_fee;
          Log.info "[engine] reconcile commit cid=%s (fallback)"
            o.client_order_id
        | Cancelled | Rejected | Expired | Failed ->
          Hashtbl.remove t.pending o.client_order_id;
          t.state <- Engine.Step.release t.state
            ~reservation_id:p.reservation_id;
          Log.info "[engine] reconcile release cid=%s (%s)"
            o.client_order_id (Order.status_to_string o.status)
        | Partially_filled | New
        | Pending_new | Pending_cancel | Suspended ->
          ()    (* still in flight; check again next tick *)
    ) orders)

let position t = with_lock t (fun () ->
  match Engine.Portfolio.position t.state.portfolio t.cfg.instrument with
  | Some p -> p.quantity
  | None -> Decimal.zero)

let portfolio t = with_lock t (fun () -> t.state.portfolio)

let placed t = with_lock t (fun () -> List.rev t.placed)

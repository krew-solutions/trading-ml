open Core

type config = {
  broker : Broker.client;
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  initial_cash : Decimal.t;
  limits : Engine.Risk.limits;
  tif : Order.time_in_force;
  fee_rate : Decimal.t;
  reconcile_every : int;
  max_drawdown_pct : float;
  rate_limit : (int * float) option;
}

type pending = {
  reservation_id : int;
  intended_quantity : Decimal.t;
  remaining_quantity : Decimal.t;
      (** Starts equal to [intended_quantity]; decreases on each
      partial fill event. When it hits zero, the reservation is
      fully settled and the [pending] entry is removed. *)
  intended_price : Decimal.t;
  intended_fee : Decimal.t;
      (** Snapshot of the numbers Step reserved against — used by
      {!reconcile} when the broker reports [Filled] without a
      granular WS event that would carry the actual fill price. *)
}
(** Live state = {!Engine.Step.state} (shared with Backtest) plus
    live-specific bookkeeping: a seq counter for unique
    [client_order_id]s and the list of submitted orders for the UI. *)

type t = {
  cfg : config;
  step_cfg : Engine.Step.config;
  mutable state : Engine.Step.state;
  mutable seq : int;
  mutable placed : Order.t list;  (** newest first *)
  pending : (string, pending) Hashtbl.t;
      (** [client_order_id → pending] for orders we've submitted to the
      broker and are waiting to confirm. Populated at [submit_order];
      consumed by {!on_fill_event} (actual numbers) or
      {!reconcile} (intended numbers as fallback). *)
  mutable bars_since_reconcile : int;
      (** Counter reset on every reconcile — triggers auto-reconcile
      after [cfg.reconcile_every] bars. *)
  mutable peak_equity : Decimal.t;
  mutable halted : bool;
  mutable recent_order_ts : float list;
      (** Timestamps of orders submitted within the rate-limit
      window, newest first. Pruned on each [submit_order] call. *)
  mutex : Mutex.t;
}

let make (cfg : config) : t =
  let step_cfg : Engine.Step.config =
    {
      limits = cfg.limits;
      instrument = cfg.instrument;
      fee_rate = cfg.fee_rate;
      auto_commit = false;
      (* Live defers commit until the broker reports a fill via
       {!on_fill_event}. Reservations stay open until then and
       properly shrink [available_cash] for subsequent Risk gates. *)
    }
  in
  {
    cfg;
    step_cfg;
    state = Engine.Step.make_state ~strategy:cfg.strategy ~cash:cfg.initial_cash;
    seq = 0;
    placed = [];
    pending = Hashtbl.create 16;
    bars_since_reconcile = 0;
    peak_equity = cfg.initial_cash;
    halted = false;
    recent_order_ts = [];
    mutex = Mutex.create ();
  }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

(** Prune [recent_order_ts] to entries within the last
    [window_seconds]; return whether the resulting count is under
    [max_orders]. *)
let rate_limit_ok t =
  match t.cfg.rate_limit with
  | None -> true
  | Some (max_orders, window_seconds) ->
      let now = Unix.gettimeofday () in
      let cutoff = now -. window_seconds in
      let recent = List.filter (fun ts -> ts >= cutoff) t.recent_order_ts in
      t.recent_order_ts <- recent;
      List.length recent < max_orders

(** Pre-submission gates (kill switch, rate limit). Return
    [`Allow] to proceed with [Broker.place_order], or [`Drop reason]
    to release the reservation and skip. *)
let check_gates t : [ `Allow | `Drop of string ] =
  if t.halted then `Drop "kill switch tripped"
  else if not (rate_limit_ok t) then `Drop "rate limit exceeded"
  else `Allow

let submit_order t ~(strat_name : string) (settled : Engine.Step.settled) =
  match check_gates t with
  | `Drop reason ->
      Log.warn "[engine] dropping order (%s) — releasing reservation" reason;
      t.state <- Engine.Step.release t.state ~reservation_id:settled.reservation_id
  | `Allow -> (
      let cid = Broker.generate_client_order_id t.cfg.broker in
      t.seq <- t.seq + 1;
      (* Record [cid → pending] BEFORE the broker call so we're ready
       for an instant fill event (Paper's listener fires synchronously
       during place_order evaluation on the next bar). *)
      Hashtbl.replace t.pending cid
        {
          reservation_id = settled.reservation_id;
          intended_quantity = settled.quantity;
          remaining_quantity = settled.quantity;
          intended_price = settled.price;
          intended_fee = settled.fee;
        };
      t.recent_order_ts <- Unix.gettimeofday () :: t.recent_order_ts;
      try
        let o =
          Broker.place_order t.cfg.broker ~instrument:t.cfg.instrument ~side:settled.side
            ~quantity:settled.quantity ~kind:Order.Market ~tif:t.cfg.tif
            ~client_order_id:cid
        in
        t.placed <- o :: t.placed;
        Log.info "[engine] %s %s qty=%s cid=%s status=%s" strat_name
          (Side.to_string settled.side)
          (Decimal.to_string settled.quantity)
          cid
          (Order.status_to_string o.status)
      with e ->
        Log.warn "[engine] place_order failed (cid=%s): %s" cid (Printexc.to_string e);
        Hashtbl.remove t.pending cid;
        t.state <- Engine.Step.release t.state ~reservation_id:settled.reservation_id)

(** Update peak-equity tracking and trip the kill switch if
    drawdown exceeds [cfg.max_drawdown_pct]. Equity is
    marked-to-market against the event's bar close. Called on
    every event regardless of whether it resulted in a trade, so
    drawdown can trip from paper losses on existing positions
    even without new trades. *)
let update_drawdown t (event : Engine.Pipeline.event) =
  if t.cfg.max_drawdown_pct > 0.0 && not t.halted then begin
    let mark _ = Some event.bar.Candle.close in
    let equity = Account.Portfolio.equity event.state.portfolio mark in
    if Decimal.compare equity t.peak_equity > 0 then t.peak_equity <- equity;
    let peak = Decimal.to_float t.peak_equity in
    let curr = Decimal.to_float equity in
    if peak > 0.0 then begin
      let drawdown = (peak -. curr) /. peak in
      if drawdown > t.cfg.max_drawdown_pct then begin
        t.halted <- true;
        Log.warn
          "[engine] kill switch tripped: drawdown=%.2f%% (peak=%s, current=%s) — halted"
          (drawdown *. 100.0)
          (Decimal.to_string t.peak_equity)
          (Decimal.to_string equity)
      end
    end
  end

(** Fold a {!Pipeline.event} into the mutable wrapper: update the
    state snapshot for external queries, submit any settled trade to
    the broker. Called under the mutex. *)
let apply_event t (event : Engine.Pipeline.event) =
  let strat_name = Strategies.Strategy.name t.state.strat in
  t.state <- event.state;
  update_drawdown t event;
  match event.settled with
  | Some (_sig, settled) -> submit_order t ~strat_name settled
  | None -> ()

(** Same as {!reconcile} but assumes the caller already holds the
    mutex — used internally by {!on_bar} to auto-trigger without
    re-entering the lock. *)
let reconcile_unsafe t =
  t.bars_since_reconcile <- 0;
  let orders =
    try Broker.get_orders t.cfg.broker
    with e ->
      Log.warn "[engine] reconcile: get_orders failed: %s" (Printexc.to_string e);
      []
  in
  List.iter
    (fun (o : Order.t) ->
      match Hashtbl.find_opt t.pending o.client_order_id with
      | None -> ()
      | Some p -> (
          match o.status with
          | Filled ->
              Hashtbl.remove t.pending o.client_order_id;
              (* Prefer actual per-execution prices from the broker over
           our intended-at-reservation-time snapshot. Empty list
           (adapter that doesn't surface executions) falls back to
           intended — bounded drift, documented in
           docs/architecture/reservations.md. *)
              let executions =
                try Broker.get_executions t.cfg.broker ~client_order_id:o.client_order_id
                with e ->
                  Log.warn "[engine] reconcile: get_executions failed for %s: %s"
                    o.client_order_id (Printexc.to_string e);
                  []
              in
              if executions = [] then begin
                t.state <-
                  Engine.Step.commit_fill t.state ~reservation_id:p.reservation_id
                    ~actual_quantity:p.intended_quantity ~actual_price:p.intended_price
                    ~actual_fee:p.intended_fee;
                Log.info "[engine] reconcile commit cid=%s (intended fallback)"
                  o.client_order_id
              end
              else begin
                List.iter
                  (fun (ex : Order.execution) ->
                    t.state <-
                      Engine.Step.commit_partial_fill t.state
                        ~reservation_id:p.reservation_id ~actual_quantity:ex.quantity
                        ~actual_price:ex.price ~actual_fee:ex.fee)
                  executions;
                Log.info "[engine] reconcile commit cid=%s (%d executions)"
                  o.client_order_id (List.length executions)
              end
          | Cancelled | Rejected | Expired | Failed ->
              Hashtbl.remove t.pending o.client_order_id;
              t.state <- Engine.Step.release t.state ~reservation_id:p.reservation_id;
              Log.info "[engine] reconcile release cid=%s (%s)" o.client_order_id
                (Order.status_to_string o.status)
          | Partially_filled | New | Pending_new | Pending_cancel | Suspended ->
              () (* still in flight; check again next tick *)))
    orders

let reconcile t = with_lock t (fun () -> reconcile_unsafe t)

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
      (* One-bar driver: feed a singleton stream through the same
       Pipeline.run that Live's streaming [run] and Backtest use. Out-
       of-order bars are filtered inside Pipeline, not here. *)
      Stream.of_list [ c ]
      |> Engine.Pipeline.run t.step_cfg t.state
      |> Stream.iter (apply_event t);
      t.bars_since_reconcile <- t.bars_since_reconcile + 1;
      if t.cfg.reconcile_every > 0 && t.bars_since_reconcile >= t.cfg.reconcile_every then
        reconcile_unsafe t)

let run t ~source =
  (* Stream driver: WS bridge pushes candles into [source], pipeline
     threads state internally, we mirror each event into [t.state] and
     route settled trades to the broker. Exactly the same
     [Pipeline.run] that Backtest consumes via [to_list + aggregate] —
     divergence in behaviour is impossible by construction. *)
  Eio_stream.of_eio_stream source
  |> Engine.Pipeline.run t.step_cfg t.state
  |> Stream.iter (fun event -> with_lock t (fun () -> apply_event t event))

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
          Log.warn "[engine] fill_event for unknown cid=%s (ignored)" fe.client_order_id
      | Some p ->
          let new_remaining = Decimal.sub p.remaining_quantity fe.actual_quantity in
          if Decimal.compare new_remaining Decimal.zero <= 0 then begin
            (* Full or over-fill — close out the pending entry; the
           reservation in Portfolio is removed by commit_fill. *)
            Hashtbl.remove t.pending fe.client_order_id;
            t.state <-
              Engine.Step.commit_fill t.state ~reservation_id:p.reservation_id
                ~actual_quantity:fe.actual_quantity ~actual_price:fe.actual_price
                ~actual_fee:fe.actual_fee;
            Log.info "[engine] commit (full) cid=%s qty=%s @ %s" fe.client_order_id
              (Decimal.to_string fe.actual_quantity)
              (Decimal.to_string fe.actual_price)
          end
          else begin
            (* Partial — shrink both our pending entry and the
           Portfolio reservation; wait for more fills. *)
            Hashtbl.replace t.pending fe.client_order_id
              { p with remaining_quantity = new_remaining };
            t.state <-
              Engine.Step.commit_partial_fill t.state ~reservation_id:p.reservation_id
                ~actual_quantity:fe.actual_quantity ~actual_price:fe.actual_price
                ~actual_fee:fe.actual_fee;
            Log.info "[engine] commit (partial) cid=%s qty=%s @ %s, %s remaining"
              fe.client_order_id
              (Decimal.to_string fe.actual_quantity)
              (Decimal.to_string fe.actual_price)
              (Decimal.to_string new_remaining)
          end)

let position t =
  with_lock t (fun () ->
      match Account.Portfolio.position t.state.portfolio t.cfg.instrument with
      | Some p -> p.quantity
      | None -> Decimal.zero)

let portfolio t = with_lock t (fun () -> t.state.portfolio)

let placed t = with_lock t (fun () -> List.rev t.placed)

let halted t = with_lock t (fun () -> t.halted)

let reset t =
  with_lock t (fun () ->
      let mark _ = None in
      t.peak_equity <- Account.Portfolio.equity t.state.portfolio mark;
      t.halted <- false;
      Log.info "[engine] reset — peak_equity=%s" (Decimal.to_string t.peak_equity))

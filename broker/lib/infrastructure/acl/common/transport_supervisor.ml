type 'event t = {
  label : string;
  ts_now : unit -> int64;
  poll_window : since_ts:int64 -> to_ts:int64 -> 'event list;
  ts_of_event : 'event -> int64;
  dedup_accept : 'event -> bool;
  emit : 'event -> unit;
  state_mutex : Eio.Mutex.t;
  mutable poll_active : bool;
  mutable last_ts : int64;
  mutable stopped : bool;
}

(** Funnel one event through dedup and (on accept) advance the
    cursor + emit. Called from both branches (WS push, REST tick).
    The cursor update + emit happen under the state mutex so a
    concurrent ws_reconnected catch-up sees a coherent [last_ts]. *)
let absorb (t : _ t) (ev : _) : unit =
  if (not t.stopped) && t.dedup_accept ev then begin
    let ts = t.ts_of_event ev in
    Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
        if Int64.compare ts t.last_ts > 0 then t.last_ts <- ts);
    try t.emit ev
    with e -> Log.warn "[%s] supervisor emit raised: %s" t.label (Printexc.to_string e)
  end

let feed_ws (t : 'event t) (ev : 'event) : unit = absorb t ev

(** REST catch-up over [(since_ts, to_ts)]. Used both by the
    steady-state poll fiber and by the on_reconnect catch-up. *)
let run_poll_window (t : _ t) ~since_ts ~to_ts : unit =
  let events =
    try t.poll_window ~since_ts ~to_ts
    with e ->
      Log.warn "[%s] supervisor poll_window raised: %s" t.label (Printexc.to_string e);
      []
  in
  List.iter (absorb t) events

let ws_came_up (t : _ t) : unit =
  if t.stopped then ()
  else
    Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
        if t.poll_active then begin
          Log.info "[%s] supervisor: ws healthy, poll dormant" t.label;
          t.poll_active <- false
        end)

let ws_went_down (t : _ t) : unit =
  if t.stopped then ()
  else
    Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () ->
        if not t.poll_active then begin
          Log.warn "[%s] supervisor: ws down, poll active" t.label;
          t.poll_active <- true
        end)

let ws_reconnected (t : _ t) : unit =
  if t.stopped then ()
  else begin
    let since_ts = Eio.Mutex.use_ro t.state_mutex (fun () -> t.last_ts) in
    let to_ts = t.ts_now () in
    Log.info "[%s] supervisor: ws reconnected, catch-up poll [%Ld..%Ld]" t.label since_ts
      to_ts;
    run_poll_window t ~since_ts ~to_ts;
    Eio.Mutex.use_rw ~protect:true t.state_mutex (fun () -> t.poll_active <- false)
  end

let stop (t : _ t) : unit =
  if not t.stopped then begin
    Log.info "[%s] supervisor: stopping" t.label;
    t.stopped <- true
  end

let start
    ~env
    ~sw
    ~label
    ~poll_interval
    ~ts_now
    ~poll_window
    ~ts_of_event
    ~dedup_accept
    ~emit
    ~initial_since_ts =
  let t =
    {
      label;
      ts_now;
      poll_window;
      ts_of_event;
      dedup_accept;
      emit;
      state_mutex = Eio.Mutex.create ();
      poll_active = true;
      last_ts = initial_since_ts;
      stopped = false;
    }
  in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.fork ~sw (fun () ->
      while not t.stopped do
        Eio.Time.sleep clock poll_interval;
        if t.stopped then ()
        else begin
          let active, since_ts =
            Eio.Mutex.use_ro t.state_mutex (fun () -> (t.poll_active, t.last_ts))
          in
          if active then run_poll_window t ~since_ts ~to_ts:(t.ts_now ())
        end
      done);
  t

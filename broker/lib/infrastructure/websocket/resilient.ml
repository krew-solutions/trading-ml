(** Resilient WebSocket connection with auto-reconnect and heartbeat. *)

type config = {
  label : string;
  ping_interval : float;
  max_backoff : float;
  connect : unit -> Client.t;
  on_text : string -> unit;
  on_reconnect : unit -> unit;
}

type t = {
  config : config;
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  mutex : Eio.Mutex.t;
  mutable client : Client.t;
  mutable closed : bool;
}

let send t msg = if not t.closed then try Client.send_text t.client msg with _ -> ()

let close t =
  if not t.closed then begin
    t.closed <- true;
    try Client.send_close t.client () with _ -> ()
  end

let is_alive t = not t.closed

let rec spawn_reader t =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      (try
         while not t.closed do
           match Client.recv t.client with
           | Text payload -> ( try t.config.on_text payload with _ -> ())
           | Binary _ | Close _ -> raise Exit
         done
       with End_of_file | Exit -> ());
      if not t.closed then reconnect t;
      `Stop_daemon)

and reconnect t =
  let clock = Eio.Stdenv.clock t.env in
  let backoff = ref 1.0 in
  let connected = ref false in
  while (not !connected) && not t.closed do
    Log.warn "[%s] disconnected — reconnecting in %.0fs" t.config.label !backoff;
    Eio.Time.sleep clock !backoff;
    if not t.closed then
      begin try
        let c = t.config.connect () in
        Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.client <- c);
        spawn_reader t;
        spawn_heartbeat t;
        (try t.config.on_reconnect () with _ -> ());
        Log.info "[%s] reconnected" t.config.label;
        connected := true;
        backoff := 1.0
      with e ->
        Log.warn "[%s] reconnect failed: %s (retry in %.0fs)" t.config.label
          (Printexc.to_string e) !backoff;
        backoff := Float.min (!backoff *. 2.0) t.config.max_backoff
      end
  done

and spawn_heartbeat t =
  let clock = Eio.Stdenv.clock t.env in
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      (try
         while not t.closed do
           Eio.Time.sleep clock t.config.ping_interval;
           if (not t.closed) && not (Client.is_closed t.client) then
             try Client.send_ping t.client () with _ -> ()
         done
       with _ -> ());
      `Stop_daemon)

let create ~env ~sw ~config =
  let client = config.connect () in
  let t = { config; env; sw; mutex = Eio.Mutex.create (); client; closed = false } in
  spawn_reader t;
  spawn_heartbeat t;
  t

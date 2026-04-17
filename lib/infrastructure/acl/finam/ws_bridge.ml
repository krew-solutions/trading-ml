(** Wires [Websocket.Client] + [Ws] DTOs together: connects to the
    Finam async endpoint *lazily* on the first subscribe call,
    multiplexes all active subscriptions on one socket, and tears
    down the connection when the last subscription is removed.

    Why lazy connect: Finam closes the WebSocket ~5 seconds after
    handshake if no subscription message has been sent. Eagerly
    connecting at server startup (before any SSE client appears)
    lost the connection before we ever had a reason to subscribe.

    JWT is pulled fresh from [Auth.t] on every outbound message (the
    asyncapi spec requires the token in the message body, not just
    at handshake), so token refresh transparently covers long-lived
    subscriptions. *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t
  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)

type bridge = {
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  cfg : Config.t;
  auth : Auth.t;
  authenticator : X509.Authenticator.t option;
  on_event : Ws.event -> unit;
  mutex : Eio.Mutex.t;
  mutable client : Websocket.Client.t option;
  (* For inbound BARS events the wire payload only carries [symbol],
     so we keep the timeframe per active subscription and use the
     symbol's [Instrument.equal] to recover it. *)
  mutable bar_subs : Timeframe.t SubMap.t;
}

let make ~env ~sw ~cfg ~auth ~on_event : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
      Printf.eprintf "[finam ws] CA load failed: %s\n%!" m;
      None
  in
  { env; sw; cfg; auth; authenticator; on_event;
    mutex = Eio.Mutex.create ();
    client = None;
    bar_subs = SubMap.empty }

(** Spawn the reader loop for a freshly-opened [client]. Runs as a
    daemon on the bridge's switch; exits when the socket closes.
    On exit it clears the bridge's client slot so the next
    [subscribe_bars] lazily reopens. *)
let spawn_reader t client =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
    (try
       let running = ref true in
       while !running do
         match Websocket.Client.recv client with
         | Text payload ->
           (try t.on_event (Ws.event_of_json
                              (Yojson.Safe.from_string payload))
            with e ->
              Printf.eprintf "[finam ws] decode failed: %s\n%!  raw: %s\n%!"
                (Printexc.to_string e) payload)
         | Binary _ | Close _ -> running := false
       done
     with End_of_file -> ());
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.client <- None;
      t.bar_subs <- SubMap.empty);
    `Stop_daemon)

let ensure_client t : Websocket.Client.t =
  match t.client with
  | Some c -> c
  | None ->
    let c =
      Websocket.Client.connect
        ~env:t.env ~sw:t.sw ~uri:t.cfg.Config.ws_url
        ?authenticator:t.authenticator ()
    in
    t.client <- Some c;
    spawn_reader t c;
    c

let subscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.subscribe_message ~token
    (Sub_bars { instrument; timeframe })
  in
  let wire = Yojson.Safe.to_string j in
  let client =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let c = ensure_client t in
      t.bar_subs <- SubMap.add (instrument, timeframe) timeframe t.bar_subs;
      c)
  in
  Websocket.Client.send_text client wire

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.unsubscribe_message ~token
    (Sub_bars { instrument; timeframe })
  in
  let wire = Yojson.Safe.to_string j in
  let action =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.bar_subs <- SubMap.remove (instrument, timeframe) t.bar_subs;
      match t.client with
      | None -> `Nothing
      | Some c when SubMap.is_empty t.bar_subs ->
        t.client <- None;
        `Send_then_close c
      | Some c -> `Send c)
  in
  match action with
  | `Nothing -> ()
  | `Send c ->
    (try Websocket.Client.send_text c wire with _ -> ())
  | `Send_then_close c ->
    (try Websocket.Client.send_text c wire with _ -> ());
    (try Websocket.Client.send_close c () with _ -> ())

(** Look up the active timeframe(s) for an inbound [Bars] event whose
    payload only carries the instrument. Multiple timeframes for the
    same instrument can be subscribed simultaneously; the bridge is
    not currently able to disambiguate which one this batch belongs
    to. For now we dispatch to all matching subscriptions (the
    [Stream] deduplicates by [(instrument, timeframe)]). *)
let timeframes_for_instrument (t : bridge) instrument : Timeframe.t list =
  Eio.Mutex.use_ro t.mutex (fun () ->
    SubMap.fold (fun (i, tf) _ acc ->
      if Instrument.equal i instrument then tf :: acc else acc)
      t.bar_subs [])

(** Wires [Websocket.Client] + [Ws] DTOs together: connects to the Finam
    async endpoint, manages a set of [(instrument, timeframe)] BARS
    subscriptions, and dispatches decoded [Bar] events to a
    caller-supplied handler.

    JWT is pulled fresh from [Auth.t] on every outbound request (the
    asyncapi spec requires the token in the message body, not just at
    handshake), so token refresh transparently covers long-lived
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
  client : Websocket.Client.t;
  auth : Auth.t;
  mutex : Eio.Mutex.t;
  (* For inbound BARS events the wire payload only carries [symbol],
     so we keep the timeframe per active subscription and use the
     symbol's [Instrument.equal] to recover it. *)
  mutable bar_subs : Timeframe.t SubMap.t;
}

let connect ~env ~sw ~cfg ~auth : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
      Printf.eprintf "[ws_bridge] CA load failed: %s\n%!" m;
      None
  in
  let client =
    Websocket.Client.connect ~env ~sw ~uri:cfg.Config.ws_url ?authenticator ()
  in
  { client; auth; mutex = Eio.Mutex.create (); bar_subs = SubMap.empty }

let subscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.subscribe_message ~token
    (Sub_bars { instrument; timeframe })
  in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    t.bar_subs <- SubMap.add (instrument, timeframe) timeframe t.bar_subs);
  Websocket.Client.send_text t.client (Yojson.Safe.to_string j)

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let token = Auth.current t.auth in
  let j = Ws.unsubscribe_message ~token
    (Sub_bars { instrument; timeframe })
  in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    t.bar_subs <- SubMap.remove (instrument, timeframe) t.bar_subs);
  (try Websocket.Client.send_text t.client (Yojson.Safe.to_string j)
   with _ -> ())

(** Look up the active timeframe(s) for an inbound [Bars] event whose
    payload only carries the instrument. Multiple timeframes for the
    same instrument can be subscribed simultaneously; the bridge is
    not currently able to disambiguate which one this batch belongs to.
    For now we dispatch to all matching subscriptions (the [Stream]
    will dedupe by [(instrument, timeframe)]). *)
let timeframes_for_instrument (t : bridge) instrument : Timeframe.t list =
  Eio.Mutex.use_ro t.mutex (fun () ->
    SubMap.fold (fun (i, tf) _ acc ->
      if Instrument.equal i instrument then tf :: acc else acc)
      t.bar_subs [])

(** Blocks forever, delivering each decoded event to [on_event].
    Returns when the underlying socket closes or raises [End_of_file]. *)
let run (t : bridge) ~(on_event : Ws.event -> unit) : unit =
  let rec loop () =
    match Websocket.Client.recv t.client with
    | Text payload ->
      (try
         let j = Yojson.Safe.from_string payload in
         on_event (Ws.event_of_json j)
       with e ->
         Printf.eprintf "[ws_bridge] decode failed: %s\n%!"
           (Printexc.to_string e));
      loop ()
    | Binary _ | Close _ -> ()
  in
  try loop ()
  with End_of_file -> ()

let close (t : bridge) = Websocket.Client.send_close t.client ()

(** Wires [Ws_client] + [Ws] DTOs together: connects to the Finam async
    endpoint, subscribes to a [(symbol, timeframe)] bars stream, and
    invokes a caller-supplied handler for each decoded [Ws.event].
    JWT is pulled fresh from the passed-in [Auth.t] at handshake time;
    on reconnect the next handshake re-reads and refreshes as needed. *)

open Core

type bridge = {
  client : Ws_client.t;
  auth : Auth.t;
}

let connect ~env ~sw ~cfg ~auth : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
      Printf.eprintf "[ws_bridge] CA load failed: %s\n%!" m;
      None
  in
  let extra_headers = [
    "Authorization", "Bearer " ^ Auth.current auth;
  ] in
  let client =
    Ws_client.connect ~env ~sw ~uri:cfg.Config.ws_url
      ~extra_headers ?authenticator ()
  in
  { client; auth }

let subscribe_bars (t : bridge) ~symbol ~timeframe ~id : unit =
  let j = Ws.subscribe_message id
    (Sub_bars { symbol; timeframe })
  in
  Ws_client.send_text t.client (Yojson.Safe.to_string j)

(** Blocks forever, delivering each decoded event to [on_event]. Returns
    when the underlying socket closes or raises [End_of_file]. *)
let run (t : bridge) ~(on_event : Ws.event -> unit) : unit =
  let rec loop () =
    match Ws_client.recv t.client with
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

let close (t : bridge) = Ws_client.send_close t.client ()

let _ = Symbol.equal

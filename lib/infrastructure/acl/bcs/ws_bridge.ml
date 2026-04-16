(** Wires BCS's per-subscription WebSocket design to the broker-agnostic
    event flow. Unlike Finam (one socket, many subscriptions), BCS
    dedicates a whole socket to each [(classCode, ticker, timeFrame)]
    stream — we track the live sockets in a map and tear each one down
    on unsubscribe. *)

open Core

module SubKey = struct
  type t = Instrument.t * Timeframe.t
  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module SubMap = Map.Make (SubKey)

type conn = {
  client : Websocket.Client.t;
  cancel : unit -> unit;
}

type bridge = {
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  cfg : Config.t;
  auth : Auth.t;
  authenticator : X509.Authenticator.t option;
  mutex : Eio.Mutex.t;
  mutable conns : conn SubMap.t;
}

let make ~env ~sw ~cfg ~auth : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
      Printf.eprintf "[bcs ws] CA load failed: %s\n%!" m;
      None
  in
  { env; sw; cfg; auth; authenticator;
    mutex = Eio.Mutex.create (); conns = SubMap.empty }

(** Convert an {!Instrument.t} to BCS's (classCode, ticker) pair —
    same policy as {!Rest.route_instrument}: honor the instrument's
    [board] when present, otherwise fall back to [default_class_code]. *)
let route (t : bridge) (i : Instrument.t) : string * string =
  Rest.route_instrument t.cfg i

let subscribe_bars (t : bridge) ~instrument ~timeframe
    ~(on_candle : Instrument.t -> Timeframe.t -> Candle.t -> unit) : unit =
  let key = instrument, timeframe in
  let already =
    Eio.Mutex.use_ro t.mutex (fun () -> SubMap.mem key t.conns)
  in
  if already then ()
  else begin
    let ticker, class_code = route t instrument in
    let extra_headers = [
      "Authorization", "Bearer " ^ Auth.current t.auth;
    ] in
    let client =
      Websocket.Client.connect
        ~env:t.env ~sw:t.sw ~uri:t.cfg.Config.ws_market_data_url
        ~extra_headers ?authenticator:t.authenticator ()
    in
    let sub_msg = Ws.subscribe_last_candle_message
      ~class_code ~ticker ~timeframe in
    Websocket.Client.send_text client (Yojson.Safe.to_string sub_msg);
    let running = ref true in
    let cancel () =
      running := false;
      try Websocket.Client.send_close client () with _ -> ()
    in
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      t.conns <- SubMap.add key { client; cancel } t.conns);
    (* Per-subscription reader fiber. Stays alive as long as the
       subscription exists; cancelled when [unsubscribe_bars] tears
       down the connection or when the server closes it. *)
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      (try
         while !running do
           match Websocket.Client.recv client with
           | Text payload ->
             (try
                let j = Yojson.Safe.from_string payload in
                (match Ws.event_of_json j with
                 | Candle_ev { instrument = _; timeframe = _; candle } ->
                   (* Honour the key we subscribed under rather than
                      trusting server-echoed fields; keeps dispatch
                      stable even if BCS omits [classCode] in some
                      frames. *)
                   on_candle instrument timeframe candle
                 | Subscribe_ack { subscribe_type; _ } ->
                   Printf.eprintf
                     "[bcs ws] %s ack for %s/%s\n%!"
                     (if subscribe_type = 0 then "subscribe" else "unsubscribe")
                     (Instrument.to_qualified instrument)
                     (Timeframe.to_string timeframe)
                 | Error_ev { code; message } ->
                   Printf.eprintf "[bcs ws] error %s: %s\n%!" code message
                 | Other _ -> ())
              with e ->
                Printf.eprintf "[bcs ws] decode failed: %s\n%!"
                  (Printexc.to_string e))
           | Binary _ | Close _ -> running := false
         done
       with End_of_file -> ());
      `Stop_daemon)
  end

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let key = instrument, timeframe in
  let conn_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match SubMap.find_opt key t.conns with
      | None -> None
      | Some c ->
        t.conns <- SubMap.remove key t.conns;
        Some c)
  in
  Option.iter (fun c ->
    let ticker, class_code = route t instrument in
    let msg = Ws.unsubscribe_last_candle_message
      ~class_code ~ticker ~timeframe in
    (try Websocket.Client.send_text c.client (Yojson.Safe.to_string msg)
     with _ -> ());
    c.cancel ()) conn_opt

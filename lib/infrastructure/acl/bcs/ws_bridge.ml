(** BCS WebSocket bridge — thin wrapper over {!Websocket.Resilient}.

    Unlike Finam (one multiplexed socket), BCS dedicates one socket
    per [(classCode, ticker, timeFrame)] subscription. Each entry in
    the connection map is a {!Websocket.Resilient.t} that handles its
    own reconnect/backoff/heartbeat. *)

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
  mutex : Eio.Mutex.t;
  mutable conns : Websocket.Resilient.t SubMap.t;
}

let make ~env ~sw ~cfg ~auth : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        Log.warn "[bcs ws] CA load failed: %s" m;
        None
  in
  { env; sw; cfg; auth; authenticator; mutex = Eio.Mutex.create (); conns = SubMap.empty }

let route (t : bridge) (i : Instrument.t) : string * string =
  Rest.route_instrument t.cfg i

let subscribe_bars
    (t : bridge)
    ~instrument
    ~timeframe
    ~(on_candle : Instrument.t -> Timeframe.t -> Candle.t -> unit) : unit =
  let key = (instrument, timeframe) in
  let already = Eio.Mutex.use_ro t.mutex (fun () -> SubMap.mem key t.conns) in
  if already then ()
  else begin
    let ticker, class_code = route t instrument in
    let label =
      Printf.sprintf "bcs ws %s/%s"
        (Instrument.to_qualified instrument)
        (Timeframe.to_string timeframe)
    in
    let send_subscribe client =
      let sub_msg = Ws.subscribe_last_candle_message ~class_code ~ticker ~timeframe in
      Websocket.Client.send_text client (Yojson.Safe.to_string sub_msg)
    in
    let config : Websocket.Resilient.config =
      {
        label;
        ping_interval = 30.0;
        max_backoff = 60.0;
        connect =
          (fun () ->
            let extra_headers = [ ("Authorization", "Bearer " ^ Auth.current t.auth) ] in
            let client =
              Websocket.Client.connect ~env:t.env ~sw:t.sw
                ~uri:t.cfg.Config.ws_market_data_url ~extra_headers
                ?authenticator:t.authenticator ()
            in
            send_subscribe client;
            client);
        on_text =
          (fun payload ->
            try
              let j = Yojson.Safe.from_string payload in
              match Ws.event_of_json j with
              | Candle_ev { instrument = _; timeframe = _; candle } ->
                  on_candle instrument timeframe candle
              | Subscribe_ack { subscribe_type; _ } ->
                  Log.info "[bcs ws] %s ack for %s/%s"
                    (if subscribe_type = 0 then "subscribe" else "unsubscribe")
                    (Instrument.to_qualified instrument)
                    (Timeframe.to_string timeframe)
              | Error_ev { code; message } ->
                  Log.warn "[bcs ws] error %s: %s" code message
              | Other _ -> ()
            with e -> Log.warn "[bcs ws] decode failed: %s" (Printexc.to_string e));
        on_reconnect = (fun () -> ());
      }
    in
    let conn = Websocket.Resilient.create ~env:t.env ~sw:t.sw ~config in
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.conns <- SubMap.add key conn t.conns)
  end

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let key = (instrument, timeframe) in
  let conn_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match SubMap.find_opt key t.conns with
        | None -> None
        | Some c ->
            t.conns <- SubMap.remove key t.conns;
            Some c)
  in
  Option.iter
    (fun c ->
      let ticker, class_code = route t instrument in
      let msg = Ws.unsubscribe_last_candle_message ~class_code ~ticker ~timeframe in
      Websocket.Resilient.send c (Yojson.Safe.to_string msg);
      Websocket.Resilient.close c)
    conn_opt

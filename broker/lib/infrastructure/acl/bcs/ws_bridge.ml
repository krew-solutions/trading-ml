(** BCS WebSocket bridge for market-data candles.

    Unlike Finam (one multiplexed socket for everything), BCS
    dedicates one socket per [(classCode, ticker, timeFrame)]
    subscription. Each entry in the connection map is a
    {!Websocket.Resilient.t} that handles its own
    reconnect/backoff/heartbeat.

    Each subscription is supervised by its own
    {!Acl_common.Transport_supervisor}: WS push is the primary
    transport, REST [Rest.bars] is the fallback that activates
    on disconnect and goes dormant on reconnect. The supervisor
    is per-subscription because the underlying socket is too —
    a disconnect of (SBER, M1) doesn't affect (SBER, M5). *)

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
  mutable supervisors : Candle.t Acl_common.Transport_supervisor.t SubMap.t;
}

let make ~env ~sw ~cfg ~auth : bridge =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        Log.warn "[bcs ws] CA load failed: %s" m;
        None
  in
  {
    env;
    sw;
    cfg;
    auth;
    authenticator;
    mutex = Eio.Mutex.create ();
    conns = SubMap.empty;
    supervisors = SubMap.empty;
  }

let route (t : bridge) (i : Instrument.t) : string * string =
  Rest.route_instrument t.cfg i

(** Conservative cadence: BCS's shortest published timeframe is
    M1 (one candle per minute), so a 60-second tick recovers
    the next candle one period late at worst. Larger timeframes
    fetch more often than strictly needed; the cost is bounded
    by [Rest.bars]'s [n=20] returning a small payload and
    Stream_dedup discarding everything we already saw. *)
let bars_poll_interval = 60.0

let subscribe_bars
    (t : bridge)
    ~instrument
    ~timeframe
    ~(poll_window : since_ts:int64 -> to_ts:int64 -> Candle.t list)
    ~(dedup_accept : Candle.t -> bool)
    ~(on_candle : Instrument.t -> Timeframe.t -> Candle.t -> unit) : unit =
  let key = (instrument, timeframe) in
  let already = Eio.Mutex.use_ro t.mutex (fun () -> SubMap.mem key t.conns) in
  if already then ()
  else begin
    let ticker, class_code = route t instrument in
    let label =
      Printf.sprintf "bcs bars %s/%s"
        (Instrument.to_qualified instrument)
        (Timeframe.to_string timeframe)
    in
    let ts_now () = Int64.of_float (Unix.gettimeofday ()) in
    let sup =
      Acl_common.Transport_supervisor.start ~env:t.env ~sw:t.sw ~label
        ~poll_interval:bars_poll_interval ~ts_now ~poll_window
        ~ts_of_event:(fun (c : Candle.t) -> c.ts)
        ~dedup_accept
        ~emit:(fun candle -> on_candle instrument timeframe candle)
        ~initial_since_ts:(ts_now ())
    in
    let send_subscribe client =
      let sub_msg = Ws.Requests.Candles.subscribe ~class_code ~ticker ~timeframe in
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
                  Acl_common.Transport_supervisor.feed_ws sup candle
              | Subscribe_ack { subscribe_type; _ } ->
                  Log.info "[bcs ws] %s ack for %s/%s"
                    (if subscribe_type = 0 then "subscribe" else "unsubscribe")
                    (Instrument.to_qualified instrument)
                    (Timeframe.to_string timeframe)
              | Error_ev { code; message } ->
                  Log.warn "[bcs ws] error %s: %s" code message
              | Other _ -> ()
            with e -> Log.warn "[bcs ws] decode failed: %s" (Printexc.to_string e));
        on_disconnect = (fun () -> Acl_common.Transport_supervisor.ws_went_down sup);
        on_reconnect = (fun () -> Acl_common.Transport_supervisor.ws_reconnected sup);
      }
    in
    (* Register the supervisor first so unsubscribe can stop it
       even if WS initial-connect raises. WS-failure path leaves
       the supervisor in [poll_active=true] (its INIT default) so
       the fallback transport carries the load. *)
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        t.supervisors <- SubMap.add key sup t.supervisors);
    try
      let conn = Websocket.Resilient.create ~env:t.env ~sw:t.sw ~config in
      Acl_common.Transport_supervisor.ws_came_up sup;
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
          t.conns <- SubMap.add key conn t.conns)
    with e ->
      Log.warn
        "[bcs ws %s] initial connect failed: %s — REST-poll only until manual resubscribe"
        label (Printexc.to_string e)
  end

let unsubscribe_bars (t : bridge) ~instrument ~timeframe : unit =
  let key = (instrument, timeframe) in
  let conn_opt, sup_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        let conn = SubMap.find_opt key t.conns in
        let sup = SubMap.find_opt key t.supervisors in
        t.conns <- SubMap.remove key t.conns;
        t.supervisors <- SubMap.remove key t.supervisors;
        (conn, sup))
  in
  Option.iter
    (fun c ->
      let ticker, class_code = route t instrument in
      let msg = Ws.Requests.Candles.unsubscribe ~class_code ~ticker ~timeframe in
      Websocket.Resilient.send c (Yojson.Safe.to_string msg);
      Websocket.Resilient.close c)
    conn_opt;
  Option.iter Acl_common.Transport_supervisor.stop sup_opt

(** Empirical probe of Finam's WebSocket dispatch, focused on the
    single question: is [subscription_key] in incoming DATA envelopes
    a server-synthesised correlator (a function of channel + data),
    or a client-supplied value echoed back from the SUBSCRIBE request?

    Load-bearing for paired strategies that subscribe to BARS on the
    same instrument at two timeframes on one connection and need to
    route every bar to its correct timeframe slot.

    Output is raw JSON for human inspection. Bypasses
    [Finam.Ws.event_of_json] on purpose — that parser drops envelope
    fields our typed DTO doesn't model, including the one we're
    investigating.

    Skipped silently when [FINAM_SECRET] is absent.

    {v
      export FINAM_SECRET=<portal secret>
      dune exec broker/test/live_smoke/finam_ws_subscription_key_probe.exe
    v}

    Best run during MOEX trading hours so M1 bars actually flow. *)

let pf fmt = Printf.printf (fmt ^^ "\n%!")

let banner s =
  pf "";
  pf "═══════════════════════════════════════════════════════════════";
  pf "PROBE: %s" s;
  pf "═══════════════════════════════════════════════════════════════"

let now_iso () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  let ms = int_of_float (Float.rem (t *. 1000.0) 1000.0) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" (tm.Unix.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec ms

let send_raw client (j : Yojson.Safe.t) =
  let s = Yojson.Safe.to_string j in
  pf "[%s] >>> %s" (now_iso ()) s;
  try Websocket.Client.send_text client s
  with e -> pf "[%s] !!! send_text raised: %s" (now_iso ()) (Printexc.to_string e)

(** Drain incoming frames for [duration_s], printing each. Returns when
    the budget elapses (via Eio cancellation), the server closes, or
    EOF is hit. After a timeout-cancel the connection state is
    inconsistent, so callers should close it and open a fresh one for
    the next probe. *)
let drain ~clock ~client ~duration_s =
  let result =
    Eio.Time.with_timeout clock duration_s (fun () ->
        let rec loop () =
          match Websocket.Client.recv client with
          | Text s ->
              pf "[%s] <<< %s" (now_iso ()) s;
              loop ()
          | Binary _ ->
              pf "[%s] <<< [binary frame]" (now_iso ());
              loop ()
          | Close { code; reason } ->
              pf "[%s] <<< CLOSE code=%s reason=%s" (now_iso ())
                (Option.fold ~none:"-" ~some:string_of_int code)
                reason;
              Ok ()
        in
        try loop () with End_of_file -> Ok ())
  in
  match result with
  | Ok () -> ()
  | Error `Timeout -> pf "[%s] (drain window of %.0fs elapsed)" (now_iso ()) duration_s

let connect ~env ~sw ~cfg =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        pf "[warn] CA load failed (%s) — proceeding without authenticator" m;
        None
  in
  Websocket.Client.connect ~env ~sw ~uri:cfg.Finam.Config.ws_url ?authenticator ()

let unsubscribe_all client ~token =
  send_raw client
    (`Assoc [ ("action", `String "UNSUBSCRIBE_ALL"); ("token", `String token) ])

let subscribe_bars client ~token ~symbol ~timeframe ?extra () =
  let base : (string * Yojson.Safe.t) list =
    [
      ("action", `String "SUBSCRIBE");
      ("type", `String "BARS");
      ("data", `Assoc [ ("symbol", `String symbol); ("timeframe", `String timeframe) ]);
      ("token", `String token);
    ]
  in
  let payload =
    match extra with
    | None -> base
    | Some kvs -> List.merge (fun (a, _) (b, _) -> compare a b) base kvs
  in
  send_raw client (`Assoc payload)

(** Probe #1 — single BARS subscription, no client [subscription_key].
    Establishes baseline: what does Finam put in the DATA envelope for
    a plain SUBSCRIBE? *)
let probe_single_no_key ~env ~clock ~cfg ~token =
  banner "1. BARS SBER@MISX M1 — no client subscription_key (baseline)";
  Eio.Switch.run @@ fun sw ->
  let c = connect ~env ~sw ~cfg in
  subscribe_bars c ~token ~symbol:"SBER@MISX" ~timeframe:"TIME_FRAME_M1" ();
  drain ~clock ~client:c ~duration_s:30.0;
  unsubscribe_all c ~token;
  Websocket.Client.send_close c ()

(** Probe #2 — two BARS subscriptions on the same instrument at
    different timeframes, one connection. The critical case for
    paired strategies. Question: can each DATA frame be routed to
    its correct timeframe slot? If [subscription_key] differs per
    subscription, yes. If not, paired strategies need a second
    socket. *)
let probe_two_timeframes ~env ~clock ~cfg ~token =
  banner "2. BARS SBER@MISX M1 + M5 on ONE connection (paired-strategy case)";
  Eio.Switch.run @@ fun sw ->
  let c = connect ~env ~sw ~cfg in
  subscribe_bars c ~token ~symbol:"SBER@MISX" ~timeframe:"TIME_FRAME_M1" ();
  subscribe_bars c ~token ~symbol:"SBER@MISX" ~timeframe:"TIME_FRAME_M5" ();
  drain ~clock ~client:c ~duration_s:90.0;
  unsubscribe_all c ~token;
  Websocket.Client.send_close c ()

(** Probe #3 — try injecting [subscription_key] into the SUBSCRIBE
    envelope. Spec doesn't define it on the client side, but
    "additionalProperties" isn't forbidden either. If the server
    echoes the value back in DATA frames → user's hypothesis holds
    (client-supplied). If the server emits its own value or rejects
    with an error → server-synthesised. *)
let probe_client_supplied_key ~env ~clock ~cfg ~token =
  banner "3. BARS SBER@MISX M1 WITH client-supplied subscription_key";
  Eio.Switch.run @@ fun sw ->
  let c = connect ~env ~sw ~cfg in
  let custom_key = "PROBE-CLIENT-KEY-XYZ-001" in
  subscribe_bars c ~token ~symbol:"SBER@MISX" ~timeframe:"TIME_FRAME_M1"
    ~extra:[ ("subscription_key", `String custom_key) ]
    ();
  pf "[hint] watching for echo of subscription_key=%S in incoming DATA" custom_key;
  drain ~clock ~client:c ~duration_s:30.0;
  unsubscribe_all c ~token;
  Websocket.Client.send_close c ()

(** Probe #4 — cross-channel: QUOTES is per-symbol, not per-timeframe.
    If the server still emits a [subscription_key] here (likely just
    the symbol), that supports the "server-synthesised, channel-shaped"
    interpretation. If absent, that supports "subscription_key is
    only present when the client opted in". *)
let probe_quotes_channel ~env ~clock ~cfg ~token =
  banner "4. QUOTES SBER@MISX (cross-channel sanity)";
  Eio.Switch.run @@ fun sw ->
  let c = connect ~env ~sw ~cfg in
  send_raw c
    (`Assoc
       [
         ("action", `String "SUBSCRIBE");
         ("type", `String "QUOTES");
         ("data", `Assoc [ ("symbols", `List [ `String "SBER@MISX" ]) ]);
         ("token", `String token);
       ]);
  drain ~clock ~client:c ~duration_s:15.0;
  unsubscribe_all c ~token;
  Websocket.Client.send_close c ()

let main () =
  match Sys.getenv_opt "FINAM_SECRET" with
  | None | Some "" ->
      pf "[SKIP] FINAM_SECRET not set — export it and re-run.";
      pf "       Best run during MOEX trading hours so M1 bars flow.";
      exit 0
  | Some secret ->
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let cfg = Finam.Config.make ~secret () in
      let transport = Http_transport.make_eio ~env in
      let auth = Finam.Auth.make ~secret ~transport ~base:cfg.rest_base in
      let token = Finam.Auth.current auth in
      let clock = Eio.Stdenv.clock env in
      pf "Finam WS endpoint: %s" (Uri.to_string cfg.ws_url);
      pf "JWT obtained, length=%d" (String.length token);
      (try probe_single_no_key ~env ~clock ~cfg ~token
       with e -> pf "[probe 1 crashed] %s" (Printexc.to_string e));
      (try probe_two_timeframes ~env ~clock ~cfg ~token
       with e -> pf "[probe 2 crashed] %s" (Printexc.to_string e));
      (try probe_client_supplied_key ~env ~clock ~cfg ~token
       with e -> pf "[probe 3 crashed] %s" (Printexc.to_string e));
      (try probe_quotes_channel ~env ~clock ~cfg ~token
       with e -> pf "[probe 4 crashed] %s" (Printexc.to_string e));
      pf "";
      pf "DONE."

let () = main ()

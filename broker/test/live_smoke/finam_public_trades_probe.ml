(** Live smoke probe for the public-tape relay (ADR 0032).

    Subscribes to Finam's INSTRUMENT_TRADES channel for a liquid
    instrument, decodes each frame through the real
    {!Finam.Ws.event_of_json} parser (the same path the adapter uses),
    and prints every relayed print with its aggressor side, tallying
    BUY / SELL / UNSPECIFIED.

    Two purposes:
    - End-to-end check that the adapter's INSTRUMENT_TRADES parser
      handles the live frame shape (vs. the doc-derived sample).
    - Practical read on the side semantics that ADR 0032's empirical
      validation was meant to give: on a liquid name during continuous
      trading, BUY and SELL should both be well-represented and roughly
      balanced; an all-one-side or all-UNSPECIFIED result is a red flag
      to investigate before trusting delta.

    Skipped silently when [FINAM_SECRET] is absent. Best run during MOEX
    continuous trading.

    {v
      export FINAM_SECRET=<portal secret>
      dune exec broker/test/live_smoke/finam_public_trades_probe.exe
    v} *)

let pf fmt = Printf.printf (fmt ^^ "\n%!")

let now_iso () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.tm_min tm.tm_sec

let side_str = function
  | Some Core.Side.Buy -> "BUY"
  | Some Core.Side.Sell -> "SELL"
  | None -> "UNSPEC"

let connect ~env ~sw ~cfg =
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        pf "[warn] CA load failed (%s) — proceeding without authenticator" m;
        None
  in
  Websocket.Client.connect ~env ~sw ~uri:cfg.Finam.Config.ws_url ?authenticator ()

let run ~env ~clock ~cfg ~token =
  Eio.Switch.run @@ fun sw ->
  let c = connect ~env ~sw ~cfg in
  let instrument = Core.Instrument.of_qualified "SBER@MISX" in
  let req = Finam.Ws.Requests.Public_trades.subscribe ~token instrument in
  Websocket.Client.send_text c (Yojson.Safe.to_string req);
  pf "[%s] subscribed INSTRUMENT_TRADES SBER@MISX — draining 60s..." (now_iso ());
  let buy = ref 0 and sell = ref 0 and unspec = ref 0 in
  let handle_text s =
    match Finam.Ws.event_of_json (Yojson.Safe.from_string s) with
    | Finam.Ws.Public_trades { instrument; trades } ->
        List.iter
          (fun (u : Finam.Ws.Events.Public_trades.update) ->
            (match u.side with
            | Some Core.Side.Buy -> incr buy
            | Some Core.Side.Sell -> incr sell
            | None -> incr unspec);
            pf "[%s] %s %-12s %s @ %s" (now_iso ())
              (Core.Instrument.to_qualified instrument)
              (side_str u.side)
              (Decimal.to_string u.quantity)
              (Decimal.to_string u.price))
          trades
    | Finam.Ws.Other j -> pf "[%s] (unparsed) %s" (now_iso ()) (Yojson.Safe.to_string j)
    | _ -> ()
  in
  (match
     Eio.Time.with_timeout clock 60.0 (fun () ->
         let rec loop () =
           match Websocket.Client.recv c with
           | Text s ->
               handle_text s;
               loop ()
           | Binary _ -> loop ()
           | Close _ -> Ok ()
         in
         try loop () with End_of_file -> Ok ())
   with
  | Ok () -> ()
  | Error `Timeout -> pf "[%s] (60s window elapsed)" (now_iso ()));
  pf "";
  pf "TALLY  buy=%d  sell=%d  unspecified=%d" !buy !sell !unspec;
  pf "Expect BUY and SELL both well-represented on a liquid name;";
  pf "all-one-side or all-UNSPEC warrants investigation before trusting delta.";
  Websocket.Client.send_close c ()

let main () =
  match Sys.getenv_opt "FINAM_SECRET" with
  | None | Some "" ->
      pf "[SKIP] FINAM_SECRET not set — export it and re-run.";
      pf "       Best run during MOEX trading hours so the tape flows.";
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
      (try run ~env ~clock ~cfg ~token
       with e -> pf "[probe crashed] %s" (Printexc.to_string e));
      pf "DONE."

let () = main ()

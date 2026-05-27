(** Live smoke probe for the public-tape relay (ADR 0032).

    Subscribes to Finam's QUOTES (L1) and INSTRUMENT_TRADES (public
    tape) channels for a liquid instrument on one connection, decodes
    both through the real {!Finam.Ws.event_of_json} parser (the same
    path the adapter uses), keeps the latest best bid/ask, and for each
    relayed print prints the prevailing L1 and a per-trade verdict:

      price >= ask  -> aggressor is a buyer (lifted the ask)
      price <= bid  -> aggressor is a seller (hit the bid)
      in spread     -> ambiguous from L1 alone

    compared to the venue-reported [side]. This settles the ADR 0032
    "to watch for" caveat directly: if BUY prints sit at the ask and
    SELL prints at the bid, [side] is the aggressor and the [of_domain]
    mapping is correct; if reversed, it is inverted and must be flipped.
    (Confirmed correct on SBER@MISX, 2026-05-27.)

    Caveat: quote/trade interleaving on the wire is mildly racy, and
    Finam emits partial QUOTES frames (no bid/ask) which carry no L1, so
    the verdict is statistical over many prints, not per-trade. Skipped
    silently when [FINAM_SECRET] is absent. Best run during MOEX
    continuous trading.

    {v
      export FINAM_SECRET=<portal secret>
      dune exec broker/test/live_smoke/finam_public_trades_probe.exe
    v} *)

let pf fmt = Printf.printf (fmt ^^ "\n%!")

let now () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
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
  Websocket.Client.send_text c
    (Yojson.Safe.to_string (Finam.Ws.Requests.Quotes.subscribe ~token [ instrument ]));
  Websocket.Client.send_text c
    (Yojson.Safe.to_string (Finam.Ws.Requests.Public_trades.subscribe ~token instrument));
  pf "[%s] subscribed QUOTES + INSTRUMENT_TRADES SBER@MISX — draining 60s..." (now ());
  let bid = ref None and ask = ref None in
  let agree = ref 0 and disagree = ref 0 and ambiguous = ref 0 and no_quote = ref 0 in
  let classify (u : Finam.Ws.Events.Public_trades.update) =
    let l1, verdict =
      match (!bid, !ask) with
      | Some b, Some a ->
          let l1 =
            Printf.sprintf "[bid %s / ask %s]" (Decimal.to_string b) (Decimal.to_string a)
          in
          let at_ask = Decimal.compare u.price a >= 0 in
          let at_bid = Decimal.compare u.price b <= 0 in
          let v =
            match (u.side, at_ask, at_bid) with
            | Some Core.Side.Buy, true, _ ->
                incr agree;
                "ok (BUY at ask)"
            | Some Core.Side.Sell, _, true ->
                incr agree;
                "ok (SELL at bid)"
            | Some Core.Side.Buy, false, true ->
                incr disagree;
                "INVERTED (BUY at bid)"
            | Some Core.Side.Sell, true, false ->
                incr disagree;
                "INVERTED (SELL at ask)"
            | _, false, false ->
                incr ambiguous;
                "in-spread (ambiguous)"
            | None, _, _ -> "unspecified side"
          in
          (l1, v)
      | _ ->
          incr no_quote;
          ("[no quote yet]", "no L1 yet")
    in
    pf "[%s] %-6s %s @ %s %s -> %s" (now ()) (side_str u.side)
      (Decimal.to_string u.quantity)
      (Decimal.to_string u.price) l1 verdict
  in
  let handle_text s =
    match
      try Some (Finam.Ws.event_of_json (Yojson.Safe.from_string s)) with _ -> None
    with
    | Some (Finam.Ws.Quote q) ->
        bid := Some q.bid;
        ask := Some q.ask
    | Some (Finam.Ws.Public_trades { trades; _ }) -> List.iter classify trades
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
  | Error `Timeout -> pf "[%s] (60s window elapsed)" (now ()));
  pf "";
  pf
    "VERDICT among L1-classifiable prints: agree=%d  INVERTED=%d  (ambiguous=%d, \
     no_quote=%d)"
    !agree !disagree !ambiguous !no_quote;
  let total = !agree + !disagree in
  if total = 0 then
    pf "inconclusive — no classifiable prints (market thin, or quotes lagged trades)"
  else if !disagree = 0 then
    pf "=> side == aggressor CONFIRMED: of_domain mapping is correct."
  else if !agree = 0 then
    pf "=> side == INVERTED: flip Buy/Sell in Trade_printed_integration_event.of_domain."
  else
    pf
      "=> MIXED (%.0f%% agree) — likely quote/trade races; widen the window and re-check."
      (100.0 *. float_of_int !agree /. float_of_int total);
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

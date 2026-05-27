(** Live smoke probe for the BCS public-tape relay (ADR 0032).

    The BCS [LastTrades] ([dataType:2]) frame shape and its [side]
    encoding are, unlike Finam's, inferred rather than captured — the
    saved BCS docs cover the candle channel, and the public-tape
    response is not spelled out there. This probe settles that
    empirically:

      1. It opens two BCS market-data sockets (BCS dedicates one socket
         per channel): [Quotes] ([dataType:3], the L1 analogue) and
         [LastTrades] ([dataType:2], the public tape).
      2. For the first few frames of each channel it prints the RAW
         JSON verbatim, so the actual field layout is observed directly
         — if our parser's assumed shape (top-level
         ticker/classCode/price/quantity/dateTime/side) is wrong, the
         dump shows the truth and parser + fixtures move together.
      3. Every trade frame is decoded through the real
         {!Bcs.Ws.event_of_json} — the same path the adapter uses — and
         the decode is shown next to the raw frame.
      4. Best-effort: if the [Quotes] frame yields a bid/ask, each print
         gets the same aggressor verdict the Finam probe produces
         (BUY at ask / SELL at bid => [side] is the aggressor; reversed
         => inverted and [of_domain] must flip). The L1 field names are
         themselves a guess, so when no bid/ask is found the verdict is
         simply withheld and the raw QUOTE dump is the deliverable.

    [--record FILE] writes each decoded print as one
    [Trade_printed_integration_event] JSON per line — the exact wire
    shape [trading backtest --tape FILE] replays.

    Skipped silently when [BCS_SECRET] (the Keycloak refresh token) is
    absent. Best run during MOEX continuous trading.

    {v
      export BCS_SECRET=<refresh token>
      dune exec broker/test/live_smoke/bcs_public_trades_probe.exe
      dune exec broker/test/live_smoke/bcs_public_trades_probe.exe -- --record /tmp/sber.tape
    v} *)

let pf fmt = Printf.printf (fmt ^^ "\n%!")

let now () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.tm_min tm.tm_sec

let side_str = function
  | Some Core.Side.Buy -> "BUY"
  | Some Core.Side.Sell -> "SELL"
  | None -> "UNSPEC"

let truncate ~max s = if String.length s <= max then s else String.sub s 0 max ^ " …"

(* The L1 field names BCS uses on the [Quotes] channel are not
   documented in the saved reference, so scan a handful of plausible
   keys at the top level and under a nested [data] object. Returns the
   first numeric match for bid and for ask independently. *)
let num_opt = function
  | `Float f -> Some (Decimal.of_float f)
  | `Int n -> Some (Decimal.of_int n)
  | `Intlit s | `String s -> ( try Some (Decimal.of_string s) with _ -> None)
  | _ -> None

let find_l1 (j : Yojson.Safe.t) : Decimal.t option * Decimal.t option =
  let open Yojson.Safe.Util in
  let scopes = [ j; member "data" j ] in
  let first keys =
    List.fold_left
      (fun acc scope ->
        match acc with
        | Some _ -> acc
        | None ->
            List.fold_left
              (fun acc k ->
                match acc with
                | Some _ -> acc
                | None -> num_opt (member k scope))
              None keys)
      None scopes
  in
  ( first [ "bid"; "bestBid"; "bidPrice"; "buy" ],
    first [ "ask"; "bestAsk"; "askPrice"; "sell"; "offer" ] )

(* Inline [Quotes] subscribe ([dataType:3]); the adapter has no quotes
   encoder of its own (it consumes only candles + the tape), so the
   probe builds the envelope directly. *)
let quotes_subscribe ~class_code ~ticker : Yojson.Safe.t =
  `Assoc
    [
      ("subscribeType", `Int 0);
      ("dataType", `Int 3);
      ( "instruments",
        `List [ `Assoc [ ("classCode", `String class_code); ("ticker", `String ticker) ] ]
      );
    ]

let run ~env ~clock ~cfg ~token ~record_oc =
  Eio.Switch.run @@ fun sw ->
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        pf "[warn] CA load failed (%s) — proceeding without authenticator" m;
        None
  in
  let connect_channel () =
    Websocket.Client.connect ~env ~sw ~uri:cfg.Bcs.Config.ws_market_data_url
      ~extra_headers:[ ("Authorization", "Bearer " ^ token) ]
      ?authenticator ()
  in
  let class_code = "TQBR" and ticker = "SBER" in
  let conn_q = connect_channel () and conn_t = connect_channel () in
  Websocket.Client.send_text conn_q
    (Yojson.Safe.to_string (quotes_subscribe ~class_code ~ticker));
  Websocket.Client.send_text conn_t
    (Yojson.Safe.to_string (Bcs.Ws.Requests.Public_trades.subscribe ~class_code ~ticker));
  pf "[%s] subscribed Quotes(dataType:3) + LastTrades(dataType:2) %s@%s — draining 60s…"
    (now ()) ticker class_code;

  let bid = ref None and ask = ref None in
  let agree = ref 0 and disagree = ref 0 and ambiguous = ref 0 and no_quote = ref 0 in
  let q_dumped = ref 0 and t_dumped = ref 0 in
  let dump_cap = 5 in

  let record (pt : Remote_broker.Events.Remote_public_trade_updated.t) =
    match record_oc with
    | None -> ()
    | Some oc ->
        output_string oc
          (Yojson.Safe.to_string
             (Broker_integration_events.Trade_printed_integration_event.yojson_of_t
                (Broker_integration_events.Trade_printed_integration_event.of_domain pt)));
        output_char oc '\n'
  in
  let classify (pt : Remote_broker.Events.Remote_public_trade_updated.t) =
    let l1, verdict =
      match (!bid, !ask) with
      | Some b, Some a ->
          let l1 =
            Printf.sprintf "[bid %s / ask %s]" (Decimal.to_string b) (Decimal.to_string a)
          in
          let at_ask = Decimal.compare pt.price a >= 0 in
          let at_bid = Decimal.compare pt.price b <= 0 in
          let v =
            match (pt.side, at_ask, at_bid) with
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
          ("[no L1 yet]", "no quote / L1 shape unknown")
    in
    pf "[%s] %-6s %s @ %s %s -> %s" (now ()) (side_str pt.side)
      (Decimal.to_string pt.quantity)
      (Decimal.to_string pt.price) l1 verdict
  in
  let handle_quote s =
    if !q_dumped < dump_cap then begin
      incr q_dumped;
      pf "[%s] RAW QUOTE #%d: %s" (now ()) !q_dumped (truncate ~max:400 s)
    end;
    match try Some (Yojson.Safe.from_string s) with _ -> None with
    | None -> ()
    | Some j ->
        let b, a = find_l1 j in
        if b <> None then bid := b;
        if a <> None then ask := a
  in
  let handle_trade s =
    if !t_dumped < dump_cap then begin
      incr t_dumped;
      pf "[%s] RAW TRADE #%d: %s" (now ()) !t_dumped (truncate ~max:400 s)
    end;
    match
      try Some (Bcs.Ws.event_of_json (Yojson.Safe.from_string s)) with _ -> None
    with
    | Some (Bcs.Ws.Public_trades_ev pt) ->
        classify pt;
        record pt
    | Some (Bcs.Ws.Error_ev { code; message }) ->
        pf "[%s] BCS error %s: %s" (now ()) code message
    | _ -> ()
  in
  let drain conn handler =
    let rec loop () =
      match Websocket.Client.recv conn with
      | Text s ->
          handler s;
          loop ()
      | Binary _ -> loop ()
      | Close _ -> ()
    in
    try loop () with End_of_file -> ()
  in
  (match
     Eio.Time.with_timeout clock 60.0 (fun () ->
         Eio.Fiber.both
           (fun () -> drain conn_q handle_quote)
           (fun () -> drain conn_t handle_trade);
         Ok ())
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
    pf
      "inconclusive — no L1-classifiable prints. Read the RAW dumps above: confirm the \
       LastTrades field layout against the parser, and whether the Quotes frame carries \
       a usable bid/ask."
  else if !disagree = 0 then
    pf "=> side == aggressor CONFIRMED: of_domain mapping is correct."
  else if !agree = 0 then
    pf "=> side == INVERTED: flip Buy/Sell in Bcs.Ws.Events.Public_trades.parse_side."
  else
    pf
      "=> MIXED (%.0f%% agree) — likely quote/trade races or a guessed L1 field; widen \
       the window and re-check."
      (100.0 *. float_of_int !agree /. float_of_int total);
  (try Websocket.Client.send_close conn_q () with _ -> ());
  try Websocket.Client.send_close conn_t () with _ -> ()

let main () =
  match Sys.getenv_opt "BCS_SECRET" with
  | None | Some "" ->
      pf "[SKIP] BCS_SECRET not set — export the Keycloak refresh token and re-run.";
      pf "       Best run during MOEX trading hours so the tape flows.";
      exit 0
  | Some _ ->
      let record_path =
        let rec find = function
          | "--record" :: v :: _ -> Some v
          | _ :: rest -> find rest
          | [] -> None
        in
        find (Array.to_list Sys.argv)
      in
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let cfg = Bcs.Config.make () in
      let transport = Http_transport.make_eio ~env in
      let token_store = Broker_persistence.Token_store.env ~name:"BCS_SECRET" in
      let auth = Bcs.Auth.make ~transport ~cfg ~token_store in
      let token =
        try Bcs.Auth.current auth
        with e ->
          pf "[FATAL] token exchange failed: %s" (Printexc.to_string e);
          exit 1
      in
      let clock = Eio.Stdenv.clock env in
      pf "BCS market-data WS: %s" (Uri.to_string cfg.ws_market_data_url);
      let record_oc = Option.map open_out record_path in
      Option.iter (fun p -> pf "recording tape -> %s" p) record_path;
      (try run ~env ~clock ~cfg ~token ~record_oc
       with e -> pf "[probe crashed] %s" (Printexc.to_string e));
      Option.iter close_out record_oc;
      pf "DONE."

let () = main ()

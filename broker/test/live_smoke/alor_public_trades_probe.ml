(** Live smoke probe for the Alor public-tape relay (ADR 0032).

    Symmetric to the Finam and BCS probes, adapted to Alor's transport:
    Alor multiplexes every subscription over ONE socket
    ([wss://api.alor.ru/ws]) and correlates inbound frames purely by a
    client-chosen [guid] echoed in each [{ "data": …, "guid": … }]
    envelope; the JWT rides in the subscribe envelope's [token] field,
    not an HTTP header. So this probe opens a single connection and
    fans two channels onto it with distinct guids:

      - the public tape ([AllTradesGetAndSubscribe]), parsed through the
        real {!Alor.Ws.Events.Public_trades.parse} — the adapter's path;
      - the order book ([OrderBookGetAndSubscribe], [depth:1]) as the L1
        oracle, subscribed inline (the adapter has no order-book encoder
        of its own — it consumes only bars + the tape).

    For the first few frames of each channel the RAW JSON is printed
    verbatim, so the real field layout is observed directly: Alor's tape
    and order-book shapes are inferred from alor.dev, not captured, so
    parser and fixtures can move together if a live frame differs. Each
    print then gets the same aggressor verdict the other probes produce
    (BUY at ask / SELL at bid => [side] is the aggressor; reversed =>
    inverted and [parse_side] must flip).

    [--record FILE] writes each decoded print as one
    [Public_trade_printed_integration_event] JSON per line — the exact wire
    shape [trading backtest --tape FILE] replays.

    Needs a refresh token in [ALOR_SECRET] and a portfolio code
    ([--portfolio D12345], default below). Skipped silently when
    [ALOR_SECRET] is absent. Best run during MOEX continuous trading.

    {v
      export ALOR_SECRET=<refresh token>
      dune exec broker/test/live_smoke/alor_public_trades_probe.exe -- --portfolio D12345
      dune exec broker/test/live_smoke/alor_public_trades_probe.exe -- --portfolio D12345 --record /tmp/sber-alor.tape
    v} *)

open Core

let pf fmt = Printf.printf (fmt ^^ "\n%!")

let now () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.tm_min tm.tm_sec

let side_str = function
  | Some Side.Buy -> "BUY"
  | Some Side.Sell -> "SELL"
  | None -> "UNSPEC"

let truncate ~max s = if String.length s <= max then s else String.sub s 0 max ^ " …"

let num_opt = function
  | `Float f -> Some (Decimal.of_float f)
  | `Int n -> Some (Decimal.of_int n)
  | `Intlit s | `String s -> ( try Some (Decimal.of_string s) with _ -> None)
  | _ -> None

(* Best-effort L1 from an [OrderBookGetAndSubscribe] data frame: the
   top-of-book bid/ask are the first entries of the [bids]/[asks]
   arrays, each an object carrying a [price]. The array/field names are
   the alor.dev shape; if a live frame differs, the RAW dump shows it. *)
let find_book_l1 (data : Yojson.Safe.t) : Decimal.t option * Decimal.t option =
  let open Yojson.Safe.Util in
  let first_price key =
    match member key data with
    | `List (x :: _) -> num_opt (member "price" x)
    | _ -> None
  in
  (first_price "bids", first_price "asks")

(* Inline order-book subscribe; mirrors [Requests.Bars] minus the
   timeframe, with [depth:1] for top-of-book only. *)
let order_book_subscribe ~(cfg : Alor.Config.t) ~token ~guid ~(instrument : Instrument.t)
    : Yojson.Safe.t =
  let group =
    match Alor.Routing.instrument_group_of cfg instrument with
    | Some g -> [ ("instrumentGroup", `String g) ]
    | None -> []
  in
  `Assoc
    ([
       ("opcode", `String "OrderBookGetAndSubscribe");
       ("code", `String (Alor.Routing.symbol_of instrument));
       ("exchange", `String (Alor.Routing.exchange_of cfg instrument));
       ("depth", `Int 1);
       ("format", `String "Simple");
       ("token", `String token);
       ("guid", `String guid);
     ]
    @ group)

let trades_guid = "probe-trades"
let book_guid = "probe-orderbook"

let run ~env ~clock ~cfg ~token ~instrument ~record_oc =
  Eio.Switch.run @@ fun sw ->
  let authenticator =
    match Http_transport.load_authenticator () with
    | Ok a -> Some a
    | Error m ->
        pf "[warn] CA load failed (%s) — proceeding without authenticator" m;
        None
  in
  let conn =
    Websocket.Client.connect ~env ~sw ~uri:cfg.Alor.Config.ws_url ?authenticator ()
  in
  Websocket.Client.send_text conn
    (Yojson.Safe.to_string
       (Alor.Ws.Requests.Public_trades.subscribe ~cfg ~token ~guid:trades_guid ~instrument
          ()));
  Websocket.Client.send_text conn
    (Yojson.Safe.to_string (order_book_subscribe ~cfg ~token ~guid:book_guid ~instrument));
  pf "[%s] subscribed AllTrades + OrderBook(depth:1) %s — draining 60s…" (now ())
    (Instrument.to_qualified instrument);

  let bid = ref None and ask = ref None in
  let agree = ref 0 and disagree = ref 0 and ambiguous = ref 0 and no_quote = ref 0 in
  let q_dumped = ref 0 and t_dumped = ref 0 in
  let dump_cap = 5 in

  let record (pt : Remote_broker.Events.Public_trade_printed.t) =
    match record_oc with
    | None -> ()
    | Some oc ->
        output_string oc
          (Yojson.Safe.to_string
             (Broker_integration_events.Public_trade_printed_integration_event.yojson_of_t
                (Broker_integration_events.Public_trade_printed_integration_event
                 .of_domain pt)));
        output_char oc '\n';
        (* Flush per record: a tape recorder must be durable on Ctrl-C /
           early termination — see the Finam/BCS probes. *)
        flush oc
  in
  let classify (pt : Remote_broker.Events.Public_trade_printed.t) =
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
            | Some Side.Buy, true, _ ->
                incr agree;
                "ok (BUY at ask)"
            | Some Side.Sell, _, true ->
                incr agree;
                "ok (SELL at bid)"
            | Some Side.Buy, false, true ->
                incr disagree;
                "INVERTED (BUY at bid)"
            | Some Side.Sell, true, false ->
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
          ("[no L1 yet]", "no book / L1 shape unknown")
    in
    pf "[%s] %-6s %s @ %s %s -> %s" (now ()) (side_str pt.side)
      (Decimal.to_string pt.quantity)
      (Decimal.to_string pt.price) l1 verdict
  in
  let handle_trade (data : Yojson.Safe.t) (raw : string) =
    if !t_dumped < dump_cap then begin
      incr t_dumped;
      pf "[%s] RAW TRADE #%d: %s" (now ()) !t_dumped (truncate ~max:400 raw)
    end;
    match
      try Some (Alor.Ws.Events.Public_trades.parse ~instrument data) with _ -> None
    with
    | Some pt ->
        classify pt;
        record pt
    | None -> ()
  in
  let handle_book (data : Yojson.Safe.t) (raw : string) =
    if !q_dumped < dump_cap then begin
      incr q_dumped;
      pf "[%s] RAW BOOK  #%d: %s" (now ()) !q_dumped (truncate ~max:400 raw)
    end;
    let b, a = find_book_l1 data in
    if b <> None then bid := b;
    if a <> None then ask := a
  in
  let handle_text s =
    match try Alor.Ws.frame_of_json (Yojson.Safe.from_string s) with _ -> None with
    | Some { guid; data } when guid = trades_guid -> handle_trade data s
    | Some { guid; data } when guid = book_guid -> handle_book data s
    | _ -> () (* subscribe confirmations / control frames *)
  in
  let drain () =
    let rec loop () =
      match Websocket.Client.recv conn with
      | Text s ->
          handle_text s;
          loop ()
      | Binary _ -> loop ()
      | Close _ -> ()
    in
    try loop () with End_of_file -> ()
  in
  (match
     Eio.Time.with_timeout clock 60.0 (fun () ->
         drain ();
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
       AllTrades field layout against the parser, and whether the OrderBook frame \
       carries a usable bids/asks top-of-book."
  else if !disagree = 0 then
    pf "=> side == aggressor CONFIRMED: parse_side mapping is correct."
  else if !agree = 0 then
    pf "=> side == INVERTED: flip Buy/Sell in Alor.Ws.Events.Public_trades.parse_side."
  else
    pf
      "=> MIXED (%.0f%% agree) — likely quote/trade races or a guessed L1 field; widen \
       the window and re-check."
      (100.0 *. float_of_int !agree /. float_of_int total);
  try Websocket.Client.send_close conn () with _ -> ()

let arg_value name =
  let rec find = function
    | k :: v :: _ when k = name -> Some v
    | _ :: rest -> find rest
    | [] -> None
  in
  find (Array.to_list Sys.argv)

let main () =
  match Sys.getenv_opt "ALOR_SECRET" with
  | None | Some "" ->
      pf "[SKIP] ALOR_SECRET not set — export the refresh token and re-run.";
      pf "       Best run during MOEX trading hours so the tape flows.";
      exit 0
  | Some refresh_token ->
      let portfolio = Option.value (arg_value "--portfolio") ~default:"D12345" in
      let record_path = arg_value "--record" in
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let cfg = Alor.Config.make ~refresh_token ~portfolio () in
      let transport = Http_transport.make_eio ~env in
      let auth = Alor.Auth.make ~transport ~cfg in
      let token =
        try Alor.Auth.current auth
        with e ->
          pf "[FATAL] token exchange failed: %s" (Printexc.to_string e);
          exit 1
      in
      let clock = Eio.Stdenv.clock env in
      let instrument =
        Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX")
          ~board:(Board.of_string "TQBR") ()
      in
      pf "Alor WS: %s  portfolio=%s" (Uri.to_string cfg.ws_url) portfolio;
      let record_oc = Option.map open_out record_path in
      Option.iter (fun p -> pf "recording tape -> %s" p) record_path;
      (try run ~env ~clock ~cfg ~token ~instrument ~record_oc
       with e -> pf "[probe crashed] %s" (Printexc.to_string e));
      Option.iter close_out record_oc;
      pf "DONE."

let () = main ()

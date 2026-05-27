(** Wire-format tests for [Finam.Ws]: per-channel subscription
    envelope encoding and inbound event decoding. Mirrors the
    asyncapi-v1.0.0 spec bundled in [finam-trade-api/specs/asyncapi/]. *)

open Core

let mk_inst ?board ticker mic =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string mic)
    ?board:(Option.map Board.of_string board)
    ()

let test_subscribe_bars_envelope () =
  let inst = mk_inst "SBER" "MISX" in
  let j =
    Finam.Ws.Requests.Bars.subscribe ~token:"JWT123" ~instrument:inst
      ~timeframe:Timeframe.D1
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "action" "SUBSCRIBE" (member "action" j |> to_string);
  Alcotest.(check string) "type" "BARS" (member "type" j |> to_string);
  Alcotest.(check string) "token in body" "JWT123" (member "token" j |> to_string);
  let data = member "data" j in
  Alcotest.(check string) "data.symbol" "SBER@MISX" (member "symbol" data |> to_string);
  Alcotest.(check string)
    "data.timeframe" "TIME_FRAME_D"
    (member "timeframe" data |> to_string)

let test_unsubscribe_bars_envelope () =
  let inst = mk_inst "SBER" "MISX" in
  let j =
    Finam.Ws.Requests.Bars.unsubscribe ~token:"T" ~instrument:inst ~timeframe:Timeframe.H1
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "action" "UNSUBSCRIBE" (member "action" j |> to_string);
  Alcotest.(check string) "type" "BARS" (member "type" j |> to_string)

let test_subscribe_quotes_envelope () =
  let a = mk_inst "SBER" "MISX" in
  let b = mk_inst "GAZP" "MISX" in
  let j = Finam.Ws.Requests.Quotes.subscribe ~token:"T" [ a; b ] in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "QUOTES" (member "type" j |> to_string);
  let symbols = member "data" j |> member "symbols" |> to_list |> List.map to_string in
  Alcotest.(check (list string)) "symbols list" [ "SBER@MISX"; "GAZP@MISX" ] symbols

let test_subscribe_account_envelope () =
  let j = Finam.Ws.Requests.Account.subscribe ~token:"T" ~account_id:"ACC1" in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "ACCOUNT" (member "type" j |> to_string);
  Alcotest.(check string)
    "data.account_id" "ACC1"
    (member "data" j |> member "account_id" |> to_string)

(** Sample DATA envelope with a BARS payload. Matches what Finam
    actually sends (observed live): [subscription_key] encodes the
    timeframe, and [payload] is itself a JSON-encoded string (gRPC→REST
    double-wrap). Our decoder must handle both idiosyncrasies. *)
let bars_data_payload =
  {|
  { "type": "DATA",
    "subscription_type": "BARS",
    "subscription_key": "SBER@MISX:TIME_FRAME_M1",
    "timestamp": 1700000000,
    "payload": "{\"symbol\":\"SBER@MISX\",\"bars\":[{\"timestamp\":\"2026-04-16T10:00:00Z\",\"open\":{\"value\":\"300.0\"},\"high\":{\"value\":\"301.5\"},\"low\":{\"value\":\"299.8\"},\"close\":{\"value\":\"301.0\"},\"volume\":{\"value\":\"12345\"}}]}" }
|}

let test_decode_bars_data () =
  let j = Yojson.Safe.from_string bars_data_payload in
  match Finam.Ws.event_of_json j with
  | Bars { instrument; timeframe; bars } ->
      Alcotest.(check string)
        "ticker round-trips" "SBER"
        (Ticker.to_string (Instrument.ticker instrument));
      Alcotest.(check string)
        "venue round-trips" "MISX"
        (Mic.to_string (Instrument.venue instrument));
      Alcotest.(check bool)
        "timeframe from subscription_key" true (timeframe = Timeframe.M1);
      Alcotest.(check int) "1 bar" 1 (List.length bars);
      let c = List.hd bars in
      Alcotest.(check (float 1e-6)) "close" 301.0 (Decimal.to_float c.Candle.close)
  | _ -> Alcotest.fail "expected Bars event"

(** Contract drift guard: a BARS envelope without [subscription_key]
    is not part of Finam's observed behaviour (probe 2026-05-22
    against [api.finam.ru/ws] showed it present on 100% of frames
    across multiple subscriptions, even when the client tries to
    suppress or override it). If it ever appears, the decoder must
    fail loudly rather than silently fabricate a timeframe, so the
    breakage is caught at the ACL boundary. *)
let test_decode_bars_without_subscription_key_raises () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "BARS",
      "payload": "{\"symbol\":\"GAZP@MISX\",\"bars\":[]}" }
  |}
  in
  Alcotest.check_raises "missing subscription_key must raise"
    (Invalid_argument
       "Finam BARS: envelope missing subscription_key (spec allows it, but Finam \
        empirically always emits it — investigate broker-side contract drift)") (fun () ->
      ignore (Finam.Ws.event_of_json j))

(** Spec-compliant form (asyncapi [SubscribeBarsResponse]): [payload]
    is a plain object and each bar's OHLCV fields are plain Decimal
    strings, not the [{"value": "..."}] wrappers the live gRPC→REST
    bridge emits today. Our decoder tolerates both so a future wire
    fix on Finam's side doesn't break us. *)
let test_decode_bars_spec_format () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "BARS",
      "subscription_key": "SBER@MISX:TIME_FRAME_M5",
      "timestamp": 1700000000,
      "payload": {
        "symbol": "SBER@MISX",
        "bars": [
          { "timestamp": "2026-04-16T10:00:00Z",
            "open": "300.0", "high": "301.5",
            "low": "299.8", "close": "301.0",
            "volume": "12345" }
        ] } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Bars { instrument; timeframe; bars } ->
      Alcotest.(check string)
        "ticker" "SBER"
        (Ticker.to_string (Instrument.ticker instrument));
      Alcotest.(check bool) "timeframe M5" true (timeframe = Timeframe.M5);
      Alcotest.(check int) "1 bar" 1 (List.length bars);
      let c = List.hd bars in
      Alcotest.(check (float 1e-6)) "close" 301.0 (Decimal.to_float c.Candle.close);
      Alcotest.(check (float 1e-6)) "volume" 12345.0 (Decimal.to_float c.Candle.volume)
  | _ -> Alcotest.fail "expected Bars event"

let test_decode_error () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "ERROR",
      "subscription_type": "BARS",
      "timestamp": 1700000000,
      "error_info": {
        "code": 401,
        "type": "UNAUTHENTICATED",
        "message": "JWT expired"
      } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Error_ev { code; type_; message } ->
      Alcotest.(check int) "code" 401 code;
      Alcotest.(check string) "type" "UNAUTHENTICATED" type_;
      Alcotest.(check string) "message" "JWT expired" message
  | _ -> Alcotest.fail "expected Error_ev"

let test_subscribe_trades_envelope () =
  let j = Finam.Ws.Requests.Trades.subscribe ~token:"T" ~account_id:"ACC1" in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "TRADES" (member "type" j |> to_string);
  Alcotest.(check string)
    "data.account_id" "ACC1"
    (member "data" j |> member "account_id" |> to_string)

let test_decode_trades () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "TRADES",
      "timestamp": 1700000000,
      "payload": {
        "trades": [
          { "trade_id": "T-001",
            "order_id": "O-100",
            "account_id": "ACC1",
            "symbol": "SBER@MISX",
            "side": "SIDE_BUY",
            "size": "10",
            "price": "302.5",
            "timestamp": "2026-04-16T10:00:00Z" },
          { "trade_id": "T-002",
            "order_id": "O-100",
            "account_id": "ACC1",
            "symbol": "SBER@MISX",
            "side": "SIDE_BUY",
            "size": "5",
            "price": "302.7",
            "timestamp": "2026-04-16T10:00:05Z" }
        ] } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Trades trades ->
      Alcotest.(check int) "two trades" 2 (List.length trades);
      let t0 = List.hd trades in
      Alcotest.(check string) "trade_id" "T-001" t0.trade_id;
      Alcotest.(check string) "order_id" "O-100" t0.order_id;
      Alcotest.(check string) "account_id" "ACC1" t0.account_id;
      Alcotest.(check string) "symbol" "SBER@MISX" (Instrument.to_qualified t0.instrument);
      Alcotest.(check string) "side BUY" "BUY" (Side.to_string t0.side);
      Alcotest.(check (float 1e-6)) "size" 10.0 (Decimal.to_float t0.quantity);
      Alcotest.(check (float 1e-6)) "price" 302.5 (Decimal.to_float t0.price)
  | _ -> Alcotest.fail "expected Trades event"

let test_decode_trades_sell_side () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "TRADES",
      "timestamp": 1700000000,
      "payload": {
        "trades": [
          { "trade_id": "T-003",
            "order_id": "O-101",
            "account_id": "ACC1",
            "symbol": "GAZP@MISX",
            "side": "SIDE_SELL",
            "size": "3",
            "price": "150.0",
            "timestamp": "2026-04-16T10:00:10Z" }
        ] } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Trades [ t ] -> Alcotest.(check string) "side SELL" "SELL" (Side.to_string t.side)
  | _ -> Alcotest.fail "expected one Trade"

let test_decode_lifecycle () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "EVENT",
      "timestamp": 1700000000,
      "event_info": {
        "event": "HANDSHAKE_SUCCESS",
        "code": 0,
        "reason": "ok"
      } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Lifecycle { event; code; reason } ->
      Alcotest.(check string) "event" "HANDSHAKE_SUCCESS" event;
      Alcotest.(check int) "code" 0 code;
      Alcotest.(check string) "reason" "ok" reason
  | _ -> Alcotest.fail "expected Lifecycle"

let test_subscribe_public_trades_envelope () =
  let inst = mk_inst "SBER" "MISX" in
  let j = Finam.Ws.Requests.Public_trades.subscribe ~token:"T" inst in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "action" "SUBSCRIBE" (member "action" j |> to_string);
  Alcotest.(check string) "type" "INSTRUMENT_TRADES" (member "type" j |> to_string);
  Alcotest.(check string)
    "data.symbol" "SBER@MISX"
    (member "data" j |> member "symbol" |> to_string)

(** Sample INSTRUMENT_TRADES DATA envelope (public tape). The side
    mapping is the load-bearing bit: SIDE_BUY/SIDE_SELL become the
    aggressor; SIDE_UNSPECIFIED (auction / negotiated, no initiator)
    becomes [None]. *)
let test_decode_public_trades () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "INSTRUMENT_TRADES",
      "subscription_key": "SBER@MISX",
      "timestamp": 1700000000,
      "payload": {
        "symbol": "SBER@MISX",
        "trades": [
          { "trade_id": "P-1", "mpid": "MM", "side": "SIDE_BUY",
            "size": "10", "price": "302.5",
            "timestamp": "2026-04-16T10:00:00Z" },
          { "trade_id": "P-2", "mpid": "MM", "side": "SIDE_SELL",
            "size": "4", "price": "302.4",
            "timestamp": "2026-04-16T10:00:01Z" },
          { "trade_id": "P-3", "mpid": "MM", "side": "SIDE_UNSPECIFIED",
            "size": "7", "price": "302.5",
            "timestamp": "2026-04-16T10:00:02Z" }
        ] } }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Public_trades { instrument; trades } -> (
      Alcotest.(check string) "symbol" "SBER@MISX" (Instrument.to_qualified instrument);
      Alcotest.(check int) "three prints" 3 (List.length trades);
      match trades with
      | [ a; b; c ] ->
          Alcotest.(check bool) "buy -> Some Buy" true (a.side = Some Side.Buy);
          Alcotest.(check bool) "sell -> Some Sell" true (b.side = Some Side.Sell);
          Alcotest.(check bool) "unspecified -> None" true (c.side = None);
          Alcotest.(check (float 1e-6)) "price" 302.5 (Decimal.to_float a.price);
          Alcotest.(check (float 1e-6)) "size" 10.0 (Decimal.to_float a.quantity)
      | _ -> Alcotest.fail "expected exactly 3 prints")
  | _ -> Alcotest.fail "expected Public_trades event"

(** Full QUOTES frame (bid + ask present, [{"value": _}]-wrapped, with
    the payload itself a JSON-encoded string as Finam sends it live). *)
let test_decode_quotes_full () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "QUOTES",
      "subscription_key": "SBER@MISX",
      "payload": "{\"quote\":[{\"symbol\":\"SBER@MISX\",\"timestamp\":\"2026-05-27T17:32:23Z\",\"bid\":{\"value\":\"322.09\"},\"ask\":{\"value\":\"322.11\"}}]}" }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Quote q ->
      Alcotest.(check (float 1e-6)) "bid" 322.09 (Decimal.to_float q.bid);
      Alcotest.(check (float 1e-6)) "ask" 322.11 (Decimal.to_float q.ask)
  | _ -> Alcotest.fail "expected Quote event"

(** Partial QUOTES frame (delta update: only size/last, no bid/ask).
    Finam emits these live; the decoder must skip them (-> Other), not
    raise on the missing decimal field. *)
let test_decode_quotes_partial_is_skipped () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "QUOTES",
      "subscription_key": "SBER@MISX",
      "payload": "{\"quote\":[{\"symbol\":\"SBER@MISX\",\"timestamp\":\"2026-05-27T17:32:27Z\",\"askSize\":{\"value\":\"171.0\"},\"last\":{\"value\":\"322.11\"}}]}" }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Other _ -> ()
  | Quote _ -> Alcotest.fail "a partial quote frame must not yield a Quote"
  | _ -> Alcotest.fail "expected Other for a partial quote frame"

let tests =
  [
    ("subscribe BARS envelope", `Quick, test_subscribe_bars_envelope);
    ("unsubscribe BARS envelope", `Quick, test_unsubscribe_bars_envelope);
    ("subscribe QUOTES envelope", `Quick, test_subscribe_quotes_envelope);
    ("subscribe ACCOUNT envelope", `Quick, test_subscribe_account_envelope);
    ("decode BARS data (sub-key + wrapped)", `Quick, test_decode_bars_data);
    ( "decode BARS without sub-key must raise",
      `Quick,
      test_decode_bars_without_subscription_key_raises );
    ("decode BARS spec format", `Quick, test_decode_bars_spec_format);
    ("decode ERROR event", `Quick, test_decode_error);
    ("decode EVENT lifecycle", `Quick, test_decode_lifecycle);
    ("subscribe TRADES envelope", `Quick, test_subscribe_trades_envelope);
    ("decode TRADES data", `Quick, test_decode_trades);
    ("decode TRADES sell side", `Quick, test_decode_trades_sell_side);
    ("subscribe INSTRUMENT_TRADES envelope", `Quick, test_subscribe_public_trades_envelope);
    ( "decode INSTRUMENT_TRADES data (buy/sell/unspecified)",
      `Quick,
      test_decode_public_trades );
    ("decode QUOTES full frame", `Quick, test_decode_quotes_full);
    ( "decode QUOTES partial frame is skipped",
      `Quick,
      test_decode_quotes_partial_is_skipped );
  ]

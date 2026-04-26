(** Wire-format tests for [Finam.Ws]: subscription envelope encoding
    and inbound event decoding. Mirrors the asyncapi-v1.0.0 spec
    bundled in [finam-trade-api/specs/asyncapi/]. *)

open Core

let mk_inst ?board ticker mic =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string mic)
    ?board:(Option.map Board.of_string board)
    ()

let test_subscribe_bars_envelope () =
  let inst = mk_inst "SBER" "MISX" in
  let j =
    Finam.Ws.subscribe_message ~token:"JWT123"
      (Sub_bars { instrument = inst; timeframe = Timeframe.D1 })
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
    Finam.Ws.unsubscribe_message ~token:"T"
      (Sub_bars { instrument = inst; timeframe = Timeframe.H1 })
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "action" "UNSUBSCRIBE" (member "action" j |> to_string);
  Alcotest.(check string) "type" "BARS" (member "type" j |> to_string)

let test_subscribe_quotes_envelope () =
  let a = mk_inst "SBER" "MISX" in
  let b = mk_inst "GAZP" "MISX" in
  let j = Finam.Ws.subscribe_message ~token:"T" (Sub_quotes [ a; b ]) in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "QUOTES" (member "type" j |> to_string);
  let symbols = member "data" j |> member "symbols" |> to_list |> List.map to_string in
  Alcotest.(check (list string)) "symbols list" [ "SBER@MISX"; "GAZP@MISX" ] symbols

let test_subscribe_account_envelope () =
  let j = Finam.Ws.subscribe_message ~token:"T" (Sub_account "ACC1") in
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
        "timeframe from subscription_key" true
        (timeframe = Some Timeframe.M1);
      Alcotest.(check int) "1 bar" 1 (List.length bars);
      let c = List.hd bars in
      Alcotest.(check (float 1e-6)) "close" 301.0 (Decimal.to_float c.Candle.close)
  | _ -> Alcotest.fail "expected Bars event"

(** Fallback path: when [subscription_key] is missing or malformed,
    the decoder still recovers the instrument from [payload.symbol]
    but leaves [timeframe] as [None] for the caller to fill in. *)
let test_decode_bars_without_subscription_key () =
  let j =
    Yojson.Safe.from_string
      {|
    { "type": "DATA",
      "subscription_type": "BARS",
      "payload": "{\"symbol\":\"GAZP@MISX\",\"bars\":[]}" }
  |}
  in
  match Finam.Ws.event_of_json j with
  | Bars { instrument; timeframe; bars = _ } ->
      Alcotest.(check string)
        "ticker recovered from payload" "GAZP"
        (Ticker.to_string (Instrument.ticker instrument));
      Alcotest.(check bool) "timeframe None without sub-key" true (timeframe = None)
  | _ -> Alcotest.fail "expected Bars event"

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
      Alcotest.(check bool) "timeframe M5" true (timeframe = Some Timeframe.M5);
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

let tests =
  [
    ("subscribe BARS envelope", `Quick, test_subscribe_bars_envelope);
    ("unsubscribe BARS envelope", `Quick, test_unsubscribe_bars_envelope);
    ("subscribe QUOTES envelope", `Quick, test_subscribe_quotes_envelope);
    ("subscribe ACCOUNT envelope", `Quick, test_subscribe_account_envelope);
    ("decode BARS data (sub-key + wrapped)", `Quick, test_decode_bars_data);
    ("decode BARS without sub-key", `Quick, test_decode_bars_without_subscription_key);
    ("decode BARS spec format", `Quick, test_decode_bars_spec_format);
    ("decode ERROR event", `Quick, test_decode_error);
    ("decode EVENT lifecycle", `Quick, test_decode_lifecycle);
  ]

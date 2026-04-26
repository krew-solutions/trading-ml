(** Wire-format tests for [Bcs.Ws]. Reference: saved copy of the
    official BCS docs "Последняя-свеча-БКС-Торговое-API.html". *)

open Core

let test_subscribe_envelope () =
  let j =
    Bcs.Ws.subscribe_last_candle_message ~class_code:"TQBR" ~ticker:"SBER"
      ~timeframe:Timeframe.M1
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "subscribeType=0" 0
    (match member "subscribeType" j with
    | `Int n -> n
    | _ -> -1);
  Alcotest.(check int)
    "dataType=1 (candles)" 1
    (match member "dataType" j with
    | `Int n -> n
    | _ -> -1);
  Alcotest.(check string) "timeFrame" "M1" (member "timeFrame" j |> to_string);
  match member "instruments" j with
  | `List [ instr ] ->
      Alcotest.(check string) "classCode" "TQBR" (member "classCode" instr |> to_string);
      Alcotest.(check string) "ticker" "SBER" (member "ticker" instr |> to_string)
  | _ -> Alcotest.fail "expected single-element instruments array"

let test_unsubscribe_envelope () =
  let j =
    Bcs.Ws.unsubscribe_last_candle_message ~class_code:"TQBR" ~ticker:"SBER"
      ~timeframe:Timeframe.H1
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "subscribeType=1" 1
    (match member "subscribeType" j with
    | `Int n -> n
    | _ -> -1)

(** CandleStick payload from the official docs. *)
let sample_candle =
  {|
  { "responseType": "CandleStick",
    "ticker":    "SBER",
    "classCode": "TQBR",
    "timeFrame": "M1",
    "open":   244.20,
    "close":  244.50,
    "high":   244.70,
    "low":    243.90,
    "volume": 3200,
    "dateTime": "2024-11-10T10:30:00.000Z" }
|}

let test_decode_candle () =
  let j = Yojson.Safe.from_string sample_candle in
  match Bcs.Ws.event_of_json j with
  | Candle_ev { instrument; timeframe; candle } ->
      Alcotest.(check string)
        "ticker" "SBER"
        (Ticker.to_string (Instrument.ticker instrument));
      Alcotest.(check (option string))
        "board from classCode" (Some "TQBR")
        (Option.map Board.to_string (Instrument.board instrument));
      Alcotest.(check bool) "timeframe M1" true (timeframe = Timeframe.M1);
      Alcotest.(check (float 1e-6)) "open" 244.20 (Decimal.to_float candle.Candle.open_);
      Alcotest.(check (float 1e-6)) "close" 244.50 (Decimal.to_float candle.Candle.close);
      Alcotest.(check (float 1e-6))
        "volume" 3200.0
        (Decimal.to_float candle.Candle.volume);
      Alcotest.(check bool) "ts > 0" true (Int64.compare candle.ts 0L > 0)
  | _ -> Alcotest.fail "expected Candle_ev"

let sample_ack =
  {|
  { "responseType":  "CandleStickSuccess",
    "subscribeType": 0,
    "ticker":        "SBER",
    "classCode":     "TQBR",
    "timeFrame":     "M1",
    "dateTime":      "2024-11-10T10:30:00.000Z" }
|}

let test_decode_ack () =
  let j = Yojson.Safe.from_string sample_ack in
  match Bcs.Ws.event_of_json j with
  | Subscribe_ack { subscribe_type; instrument; timeframe } ->
      Alcotest.(check int) "subscribeType" 0 subscribe_type;
      Alcotest.(check string)
        "ticker" "SBER"
        (Ticker.to_string (Instrument.ticker instrument));
      Alcotest.(check bool) "timeframe" true (timeframe = Timeframe.M1)
  | _ -> Alcotest.fail "expected Subscribe_ack"

let sample_error =
  {|
  { "responseType": "CandleStick",
    "errors": [
      { "message": "Input JSON structure does not match structure, 'timeFrame' field is undefined.",
        "code":    "INCORRECT_JSON" }
    ] }
|}

let test_decode_error () =
  let j = Yojson.Safe.from_string sample_error in
  match Bcs.Ws.event_of_json j with
  | Error_ev { code; message } ->
      Alcotest.(check string) "code" "INCORRECT_JSON" code;
      Alcotest.(check bool) "message non-empty" true (String.length message > 0)
  | _ -> Alcotest.fail "expected Error_ev"

let test_decode_unknown_passes () =
  let j = Yojson.Safe.from_string {| { "responseType": "Heartbeat" } |} in
  match Bcs.Ws.event_of_json j with
  | Other _ -> ()
  | _ -> Alcotest.fail "expected Other"

let test_timeframe_round_trips () =
  let cases = [ Timeframe.M1; M5; M15; M30; H1; H4; D1; W1; MN1 ] in
  List.iter
    (fun tf ->
      let wire = Bcs.Rest.timeframe_wire tf in
      match Bcs.Ws.timeframe_of_string wire with
      | Some tf' -> Alcotest.(check bool) ("round-trip " ^ wire) true (tf = tf')
      | None -> Alcotest.failf "timeframe_of_string rejected %S" wire)
    cases

let tests =
  [
    ("subscribe envelope", `Quick, test_subscribe_envelope);
    ("unsubscribe envelope", `Quick, test_unsubscribe_envelope);
    ("decode candle event", `Quick, test_decode_candle);
    ("decode subscribe ack", `Quick, test_decode_ack);
    ("decode error event", `Quick, test_decode_error);
    ("decode unknown passes through", `Quick, test_decode_unknown_passes);
    ("timeframe wire round-trips", `Quick, test_timeframe_round_trips);
  ]

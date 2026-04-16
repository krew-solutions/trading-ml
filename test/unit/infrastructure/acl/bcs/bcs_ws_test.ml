(** Wire-format tests for [Bcs.Ws]. Reference: [bcs-trade-go] client. *)

open Core

let test_subscribe_last_candle_envelope () =
  let j = Bcs.Ws.subscribe_last_candle_message
    ~class_code:"TQBR" ~ticker:"SBER" ~timeframe:Timeframe.M1 in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "action"
    "subscribe" (member "action" j |> to_string);
  Alcotest.(check string) "classCode"
    "TQBR" (member "classCode" j |> to_string);
  Alcotest.(check string) "ticker"
    "SBER" (member "ticker" j |> to_string);
  Alcotest.(check string) "timeFrame"
    "M1" (member "timeFrame" j |> to_string)

(** Sample CandleMessage payload in [bcs-trade-go] shape: flat envelope
    with classCode, ticker, timeFrame, embedded [bar] object. OHLCV as
    JSON numbers, time as ISO-8601 string. *)
let sample_candle_json = {|
  { "type":      "candle",
    "ticker":    "SBER",
    "classCode": "TQBR",
    "timeFrame": "M1",
    "bar": {
      "open":   320.5,
      "high":   321.0,
      "low":    319.8,
      "close":  320.7,
      "volume": 1234,
      "time":   "2026-04-16T10:00:00Z"
    } }
|}

let test_decode_candle_event () =
  let j = Yojson.Safe.from_string sample_candle_json in
  match Bcs.Ws.event_of_json j with
  | Candle_ev { instrument; timeframe; candle } ->
    Alcotest.(check string) "ticker recovered"
      "SBER" (Ticker.to_string (Instrument.ticker instrument));
    Alcotest.(check (option string)) "classCode → board"
      (Some "TQBR") (Option.map Board.to_string (Instrument.board instrument));
    Alcotest.(check bool) "timeframe M1" true (timeframe = Timeframe.M1);
    Alcotest.(check (float 1e-6)) "close" 320.7
      (Decimal.to_float candle.Candle.close);
    Alcotest.(check bool) "ts > 0" true (Int64.compare candle.ts 0L > 0)
  | Other _ -> Alcotest.fail "expected Candle_ev"

let test_decode_other () =
  let j = Yojson.Safe.from_string {| { "type": "status", "status": "ok" } |} in
  match Bcs.Ws.event_of_json j with
  | Other _ -> ()
  | _ -> Alcotest.fail "expected Other"

let test_timeframe_round_trips () =
  let cases = [
    Timeframe.M1;  M5;  M15; M30;
    H1;  H4;  D1;  W1;  MN1
  ] in
  List.iter (fun tf ->
    let wire = Bcs.Rest.timeframe_wire tf in
    match Bcs.Ws.timeframe_of_string wire with
    | Some tf' -> Alcotest.(check bool)
                    ("round-trip " ^ wire) true (tf = tf')
    | None -> Alcotest.failf "timeframe_of_string rejected %S" wire
  ) cases

let tests = [
  "subscribe last_candle envelope", `Quick, test_subscribe_last_candle_envelope;
  "decode candle event",            `Quick, test_decode_candle_event;
  "decode unknown passes through",  `Quick, test_decode_other;
  "timeframe wire round-trips",     `Quick, test_timeframe_round_trips;
]

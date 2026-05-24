(** Wire-format tests for [Bcs.Ws]: per-channel subscription
    envelope encoding and inbound event decoding. Reference:
    saved copy of the official BCS docs
    "Последняя-свеча-БКС-Торговое-API.html". *)

open Core

let test_subscribe_envelope () =
  let j =
    Bcs.Ws.Requests.Candles.subscribe ~class_code:"TQBR" ~ticker:"SBER"
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
    Bcs.Ws.Requests.Candles.unsubscribe ~class_code:"TQBR" ~ticker:"SBER"
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

(** Sample execution-status payload — taken verbatim from the
    BCS documentation page
    https://trade-api.bcs.ru/websocket/operations/execution-status/.
    A complete fill of a market order ([executionType=2 Filled]
    in the aggregate, but {!Order_event.is_fill} answers false
    here because the per-leg discriminator is [11 Trade], not
    [2]). *)
let order_event_filled_sample =
  {|
  { "originalClientOrderId": "517661df-d051-461d-9389-988abf24de4d",
    "clientOrderId": "",
    "data": {
      "messageType": "8",
      "orderStatus": "2",
      "executionType": "2",
      "orderQuantity": 100,
      "executedQuantity": 100,
      "lastQuantity": 50,
      "remainedQuantity": 0,
      "ticker": "SBER",
      "classCode": "TQBR",
      "side": "1",
      "orderType": "2",
      "averagePrice": 244.5,
      "orderId": "20241030-TQBR-12345678910",
      "executionId": "TQBR-Z3fE7c-S-1-1-N",
      "price": 244.5,
      "currency": "RUB",
      "clientCode": "123456",
      "transactionTime": "2024-10-30T09:01:00.000Z",
      "tradeDate": "2024-10-30",
      "orderNumber": "12345678910",
      "accruedCoupon": 0,
      "executionValue": 24450,
      "commission": 12.3,
      "securityExchange": "TQBR"
    } }
|}

let test_decode_order_event_aggregate_state () =
  let j = Yojson.Safe.from_string order_event_filled_sample in
  match Bcs.Ws.Events.Order_event.parse j with
  | None -> Alcotest.fail "expected Some parse result"
  | Some ev ->
      Alcotest.(check string)
        "original_client_order_id round-trip" "517661df-d051-461d-9389-988abf24de4d"
        ev.original_client_order_id;
      Alcotest.(check string) "ticker" "SBER" ev.ticker;
      Alcotest.(check string) "class_code" "TQBR" ev.class_code;
      Alcotest.(check string) "execution_id" "TQBR-Z3fE7c-S-1-1-N" ev.execution_id;
      Alcotest.(check bool) "side parsed as Buy" true (ev.side = Side.Buy);
      Alcotest.(check (float 1e-6))
        "last_quantity = 50" 50.0
        (Decimal.to_float ev.last_quantity);
      Alcotest.(check (float 1e-6))
        "average_price = 244.5" 244.5
        (Decimal.to_float ev.average_price);
      Alcotest.(check (float 1e-6))
        "commission = 12.3" 12.3
        (Decimal.to_float ev.commission);
      Alcotest.(check bool)
        "executionType=2 is NOT per-leg fill" false
        (Bcs.Ws.Events.Order_event.is_fill ev);
      Alcotest.(check bool)
        "to_domain returns None on non-Trade event" true
        (Bcs.Ws.Events.Order_event.to_domain ~placement_id:42
           ~new_total_filled:Decimal.zero ev
        = None)

(** Same payload with [executionType] forced to ["11"] (Trade).
    Verifies that {!Order_event.is_fill} flips and {!to_domain}
    constructs an [Order_filled] with the expected
    discriminators. *)
let test_decode_order_event_trade_leg () =
  let j =
    Yojson.Safe.from_string
      (String.concat ""
         [
           {|{ "originalClientOrderId": "517661df-d051-461d-9389-988abf24de4d",
              "clientOrderId": "",
              "data": {
                "messageType": "8",
                "orderStatus": "1",
                "executionType": "11",
                "orderQuantity": 100,
                "executedQuantity": 50,
                "lastQuantity": 50,
                "remainedQuantity": 50,
                "ticker": "SBER",
                "classCode": "TQBR",
                "side": "2",
                "orderType": "2",
                "averagePrice": 244.5,
                "orderId": "20241030-TQBR-12345678910",
                "executionId": "TQBR-Z3fE7c-S-1-1-N",
                "price": 244.5,
                "currency": "RUB",
                "transactionTime": "2024-10-30T09:01:00.000Z",
                "commission": 6.15
              } }|};
         ])
  in
  match Bcs.Ws.Events.Order_event.parse j with
  | None -> Alcotest.fail "expected Some parse result"
  | Some ev -> (
      Alcotest.(check bool)
        "executionType=11 is a fill" true
        (Bcs.Ws.Events.Order_event.is_fill ev);
      Alcotest.(check bool) "side parsed as Sell" true (ev.side = Side.Sell);
      match
        Bcs.Ws.Events.Order_event.to_domain ~placement_id:42
          ~new_total_filled:(Decimal.of_int 50) ev
      with
      | None -> Alcotest.fail "expected Some domain event on Trade"
      | Some dom ->
          Alcotest.(check int) "placement_id round-trip" 42 dom.placement_id;
          Alcotest.(check string)
            "trade_id = executionId" "TQBR-Z3fE7c-S-1-1-N" dom.trade_id;
          Alcotest.(check (float 1e-6))
            "fill_quantity = 50" 50.0
            (Decimal.to_float dom.fill_quantity);
          Alcotest.(check (float 1e-6))
            "fill_price = 244.5" 244.5
            (Decimal.to_float dom.fill_price);
          Alcotest.(check (float 1e-6))
            "new_total_filled passed through" 50.0
            (Decimal.to_float dom.new_total_filled))

let test_decode_order_event_malformed_returns_none () =
  let j = Yojson.Safe.from_string {| { "no": "data subtree" } |} in
  Alcotest.(check bool)
    "malformed envelope returns None" true
    (Bcs.Ws.Events.Order_event.parse j = None)

let tests =
  [
    ("subscribe envelope", `Quick, test_subscribe_envelope);
    ("unsubscribe envelope", `Quick, test_unsubscribe_envelope);
    ("decode candle event", `Quick, test_decode_candle);
    ("decode subscribe ack", `Quick, test_decode_ack);
    ("decode error event", `Quick, test_decode_error);
    ("decode unknown passes through", `Quick, test_decode_unknown_passes);
    ("timeframe wire round-trips", `Quick, test_timeframe_round_trips);
    ( "decode order event — aggregate state (executionType=2)",
      `Quick,
      test_decode_order_event_aggregate_state );
    ( "decode order event — per-leg trade (executionType=11)",
      `Quick,
      test_decode_order_event_trade_leg );
    ( "decode order event — malformed returns None",
      `Quick,
      test_decode_order_event_malformed_returns_none );
  ]

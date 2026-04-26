(** Tests for Finam order DTO: wire-format encoding of PlaceOrder body
    and decoding of OrderState responses. Sample JSON from the official
    Finam REST API docs (GetOrders / PlaceOrder / GetOrder). *)

open Core

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

(** --- Encoding --- *)

let test_place_order_payload_limit () =
  let j =
    Finam.Dto.place_order_payload ~instrument:sber ~side:Buy ~quantity:(Decimal.of_int 10)
      ~kind:(Limit (Decimal.of_float 150.50))
      ~tif:DAY ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "symbol qualified" "SBER@MISX" (member "symbol" j |> to_string);
  Alcotest.(check string) "side" "SIDE_BUY" (member "side" j |> to_string);
  Alcotest.(check string) "type" "ORDER_TYPE_LIMIT" (member "type" j |> to_string);
  Alcotest.(check string) "tif" "TIME_IN_FORCE_DAY" (member "time_in_force" j |> to_string);
  (* quantity and prices must use {"value":"..."} wrapper *)
  Alcotest.(check string)
    "quantity wrapped" "10"
    (member "quantity" j |> member "value" |> to_string);
  Alcotest.(check string)
    "limit_price wrapped" "150.5"
    (member "limit_price" j |> member "value" |> to_string)

let test_place_order_payload_market () =
  let j =
    Finam.Dto.place_order_payload ~instrument:sber ~side:Sell ~quantity:(Decimal.of_int 5)
      ~kind:Market ~tif:IOC ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "ORDER_TYPE_MARKET" (member "type" j |> to_string);
  Alcotest.(check string) "tif" "TIME_IN_FORCE_IOC" (member "time_in_force" j |> to_string);
  (* Market orders have no price fields *)
  Alcotest.(check bool) "no limit_price" true (member "limit_price" j = `Null);
  Alcotest.(check bool) "no stop_price" true (member "stop_price" j = `Null)

let test_place_order_payload_stop_limit () =
  let j =
    Finam.Dto.place_order_payload ~instrument:sber ~side:Buy ~quantity:(Decimal.of_int 1)
      ~kind:(Stop_limit { stop = Decimal.of_float 300.0; limit = Decimal.of_float 305.0 })
      ~tif:GTC ~client_order_id:"my-id-123" ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "type" "ORDER_TYPE_STOP_LIMIT" (member "type" j |> to_string);
  Alcotest.(check string)
    "stop_price.value" "300"
    (member "stop_price" j |> member "value" |> to_string);
  Alcotest.(check string)
    "limit_price.value" "305"
    (member "limit_price" j |> member "value" |> to_string);
  Alcotest.(check string)
    "client_order_id" "my-id-123"
    (member "client_order_id" j |> to_string)

(** --- Decoding --- *)

(** Sample from the official docs (PlaceOrder / GetOrder response). *)
let sample_order_state =
  {|
  {
    "order_id": "12345678",
    "exec_id": "exec-001",
    "status": "ORDER_STATUS_NEW",
    "order": {
      "account_id": "ACC1",
      "symbol": "SBER@MISX",
      "quantity": { "value": "10" },
      "side": "SIDE_BUY",
      "type": "ORDER_TYPE_LIMIT",
      "time_in_force": "TIME_IN_FORCE_DAY",
      "limit_price": { "value": "150.50" },
      "stop_price": { "value": "0" },
      "stop_condition": "STOP_CONDITION_UNSPECIFIED",
      "legs": [],
      "client_order_id": "coid-abc",
      "valid_before": "VALID_BEFORE_END_OF_DAY",
      "comment": ""
    },
    "transact_at": "2026-04-17T10:00:00Z",
    "accept_at": "2026-04-17T10:00:01Z",
    "withdraw_at": "",
    "initial_quantity": { "value": "10" },
    "executed_quantity": { "value": "0" },
    "remaining_quantity": { "value": "10" }
  }
|}

let test_decode_order_state () =
  let o = Finam.Dto.order_of_json (Yojson.Safe.from_string sample_order_state) in
  Alcotest.(check string) "order_id" "12345678" o.id;
  Alcotest.(check string) "exec_id" "exec-001" o.exec_id;
  Alcotest.(check string) "status" "NEW" (Order.status_to_string o.status);
  Alcotest.(check string) "side" "BUY" (Side.to_string o.side);
  Alcotest.(check string)
    "instrument" "SBER"
    (Ticker.to_string (Instrument.ticker o.instrument));
  Alcotest.(check (float 1e-6)) "quantity" 10.0 (Decimal.to_float o.quantity);
  Alcotest.(check (float 1e-6)) "filled" 0.0 (Decimal.to_float o.filled);
  Alcotest.(check (float 1e-6)) "remaining" 10.0 (Decimal.to_float o.remaining);
  Alcotest.(check string) "kind" "LIMIT" (Order.kind_to_string o.kind);
  (match o.kind with
  | Limit p -> Alcotest.(check (float 1e-6)) "limit price" 150.50 (Decimal.to_float p)
  | _ -> Alcotest.fail "expected Limit");
  Alcotest.(check string) "tif" "DAY" (Order.tif_to_string o.tif);
  Alcotest.(check string) "client_order_id" "coid-abc" o.client_order_id;
  Alcotest.(check bool) "ts > 0" true (Int64.compare o.created_ts 0L > 0)

let test_decode_partially_filled () =
  let j =
    Yojson.Safe.from_string
      {|
    {
      "order_id": "999",
      "exec_id": "",
      "status": "ORDER_STATUS_PARTIALLY_FILLED",
      "order": {
        "symbol": "GAZP@MISX",
        "quantity": { "value": "100" },
        "side": "SIDE_SELL",
        "type": "ORDER_TYPE_MARKET",
        "time_in_force": "TIME_IN_FORCE_IOC",
        "client_order_id": ""
      },
      "initial_quantity": { "value": "100" },
      "executed_quantity": { "value": "60" },
      "remaining_quantity": { "value": "40" }
    }
  |}
  in
  let o = Finam.Dto.order_of_json j in
  Alcotest.(check string) "status" "PARTIALLY_FILLED" (Order.status_to_string o.status);
  Alcotest.(check (float 1e-6)) "filled" 60.0 (Decimal.to_float o.filled);
  Alcotest.(check (float 1e-6)) "remaining" 40.0 (Decimal.to_float o.remaining)

let test_decode_orders_list () =
  let j =
    Yojson.Safe.from_string (Printf.sprintf {| { "orders": [ %s ] } |} sample_order_state)
  in
  let orders = Finam.Dto.orders_of_json j in
  Alcotest.(check int) "1 order" 1 (List.length orders);
  Alcotest.(check string) "first order_id" "12345678" (List.hd orders).id

let tests =
  [
    ("encode limit order body", `Quick, test_place_order_payload_limit);
    ("encode market order body", `Quick, test_place_order_payload_market);
    ("encode stop-limit order body", `Quick, test_place_order_payload_stop_limit);
    ("decode order state", `Quick, test_decode_order_state);
    ("decode partially filled", `Quick, test_decode_partially_filled);
    ("decode orders list", `Quick, test_decode_orders_list);
  ]

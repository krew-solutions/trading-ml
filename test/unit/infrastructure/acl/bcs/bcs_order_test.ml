(** Wire-format tests for BCS order encoding and decoding.
    Reference: official BCS docs (create order curl) + bcs-trade-go
    models/orders.go. *)

open Core
open Bcs

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX")
    ~board:(Board.of_string "TQBR") ()

(** --- Encoding (create_order payload construction) --- *)

let make_cfg () =
  Config.make
    ~rest_base:(Uri.of_string "https://api.test")
    ~token_endpoint:(Uri.of_string "https://api.test/token")
    ()

let test_create_limit_order_payload () =
  (* We can't call create_order directly (it hits the network), but
     we can verify the wire format by building what route_instrument
     produces and checking the BCS enum conventions. *)
  let ticker, class_code = Rest.route_instrument (make_cfg ()) sber in
  Alcotest.(check string) "ticker" "SBER" ticker;
  Alcotest.(check string) "classCode" "TQBR" class_code;
  (* Side and orderType enums *)
  Alcotest.(check string) "buy side" "1" (Rest.bcs_side_of Buy);
  Alcotest.(check string) "sell side" "2" (Rest.bcs_side_of Sell);
  Alcotest.(check string) "market type" "1" (Rest.bcs_order_type_of Market);
  Alcotest.(check string)
    "limit type" "2"
    (Rest.bcs_order_type_of (Limit (Decimal.of_float 150.0)))

(** --- Decoding (OrderStatus JSON → Order.t) --- *)

let sample_order_status =
  {|
  {
    "clientOrderId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "exchangeId": "EX001",
    "status": "NEW",
    "side": "1",
    "orderType": "2",
    "ticker": "SBER",
    "classCode": "TQBR",
    "orderQuantity": 10,
    "filledQuantity": 0,
    "price": 150.50,
    "averagePrice": 0,
    "createdAt": "2026-04-17T10:00:00Z",
    "updatedAt": "2026-04-17T10:00:00Z"
  }
|}

let test_decode_order_status () =
  let cfg = make_cfg () in
  let o = Rest.bcs_order_of_json cfg (Yojson.Safe.from_string sample_order_status) in
  Alcotest.(check string) "id" "3fa85f64-5717-4562-b3fc-2c963f66afa6" o.id;
  Alcotest.(check string) "exchangeId" "EX001" o.exec_id;
  Alcotest.(check string) "status" "NEW" (Order.status_to_string o.status);
  Alcotest.(check string) "side" "BUY" (Side.to_string o.side);
  Alcotest.(check string)
    "ticker" "SBER"
    (Ticker.to_string (Instrument.ticker o.instrument));
  Alcotest.(check (option string))
    "board" (Some "TQBR")
    (Option.map Board.to_string (Instrument.board o.instrument));
  Alcotest.(check (float 1e-6)) "quantity" 10.0 (Decimal.to_float o.quantity);
  Alcotest.(check (float 1e-6)) "filled" 0.0 (Decimal.to_float o.filled);
  Alcotest.(check (float 1e-6)) "remaining" 10.0 (Decimal.to_float o.remaining);
  Alcotest.(check string) "kind" "LIMIT" (Order.kind_to_string o.kind);
  (match o.kind with
  | Limit p -> Alcotest.(check (float 1e-6)) "price" 150.50 (Decimal.to_float p)
  | _ -> Alcotest.fail "expected Limit");
  Alcotest.(check bool) "ts > 0" true (Int64.compare o.created_ts 0L > 0)

let test_decode_filled_market () =
  let j =
    Yojson.Safe.from_string
      {|
    {
      "clientOrderId": "uuid-2",
      "exchangeId": "EX002",
      "status": "FILLED",
      "side": "2",
      "orderType": "1",
      "ticker": "GAZP",
      "classCode": "TQBR",
      "orderQuantity": 5,
      "filledQuantity": 5,
      "price": 0,
      "averagePrice": 180.25,
      "createdAt": "2026-04-17T11:00:00Z",
      "updatedAt": "2026-04-17T11:00:01Z"
    }
  |}
  in
  let o = Rest.bcs_order_of_json (make_cfg ()) j in
  Alcotest.(check string) "status" "FILLED" (Order.status_to_string o.status);
  Alcotest.(check string) "side" "SELL" (Side.to_string o.side);
  Alcotest.(check string) "kind" "MARKET" (Order.kind_to_string o.kind);
  Alcotest.(check (float 1e-6)) "filled" 5.0 (Decimal.to_float o.filled);
  Alcotest.(check (float 1e-6)) "remaining" 0.0 (Decimal.to_float o.remaining)

let test_decode_orders_list () =
  let j =
    Yojson.Safe.from_string
      (Printf.sprintf {| { "orders": [ %s ] } |} sample_order_status)
  in
  let cfg = make_cfg () in
  let open Yojson.Safe.Util in
  let orders =
    match member "orders" j with
    | `List items -> List.map (Rest.bcs_order_of_json cfg) items
    | _ -> []
  in
  Alcotest.(check int) "1 order" 1 (List.length orders);
  Alcotest.(check string)
    "first id" "3fa85f64-5717-4562-b3fc-2c963f66afa6" (List.hd orders).id

let test_status_mapping () =
  let cases =
    [
      ("NEW", Order.New);
      ("FILLED", Filled);
      ("PARTIALLY_FILLED", Partially_filled);
      ("CANCELED", Cancelled);
      ("CANCELLED", Cancelled);
      ("REJECTED", Rejected);
      ("EXPIRED", Expired);
    ]
  in
  List.iter
    (fun (wire, expected) ->
      let got = Rest.bcs_status_of_wire wire in
      Alcotest.(check string)
        ("status " ^ wire)
        (Order.status_to_string expected)
        (Order.status_to_string got))
    cases

let tests =
  [
    ("BCS order enums", `Quick, test_create_limit_order_payload);
    ("decode order status", `Quick, test_decode_order_status);
    ("decode filled market", `Quick, test_decode_filled_market);
    ("decode orders list", `Quick, test_decode_orders_list);
    ("status mapping both forms", `Quick, test_status_mapping);
  ]

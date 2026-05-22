(** Wire-format tests for the BCS Deals (executions) decoder.
    Reference: BCS retail-API docs — [records] payload with
    [orderNum], [tradeNum], [ticker], [classCode], [side],
    [tradeQuantity], [tradeDateTime], [price]. *)

open Core
open Bcs

(* Faithful record per the doc schema. Omitted fields outside
   the domain model ([clientCode], currencies, [go],
   [contractAmount], [settleDate]) are accepted but not
   consumed. *)
let sample_deal =
  {|
  {
    "orderNum": 1234567890,
    "tradeNum": 9876543210,
    "ticker": "SBER",
    "classCode": "TQBR",
    "side": "1",
    "tradeDateTime": "2026-04-17T10:00:05Z",
    "price": 150.50,
    "volume": 1505.00,
    "tradeQuantity": 10,
    "tradeQuantityLots": 1
  }
|}

let test_decode_single_deal () =
  let e = Rest.bcs_trade_of_json (Yojson.Safe.from_string sample_deal) in
  Alcotest.(check string) "orderNum stringified" "1234567890" e.order_num;
  Alcotest.(check string) "tradeNum stringified" "9876543210" e.trade_id;
  Alcotest.(check string)
    "ticker round-trips" "SBER"
    (Ticker.to_string (Instrument.ticker e.instrument));
  Alcotest.(check (option string))
    "board from classCode" (Some "TQBR")
    (Option.map Board.to_string (Instrument.board e.instrument));
  Alcotest.(check bool) "side=1 parsed as Buy" true (e.side = Side.Buy);
  Alcotest.(check (float 1e-6)) "tradeQuantity" 10.0 (Decimal.to_float e.quantity);
  Alcotest.(check (float 1e-6)) "price" 150.50 (Decimal.to_float e.price);
  Alcotest.(check (float 1e-6))
    "fee always 0 (no wire field)" 0.0 (Decimal.to_float e.fee);
  Alcotest.(check bool) "ts parsed" true (Int64.compare e.ts 0L > 0)

let test_decode_sell_side () =
  let j =
    Yojson.Safe.from_string
      {|
    {
      "orderNum": 42,
      "tradeNum": 17,
      "ticker": "GAZP",
      "classCode": "TQBR",
      "side": "2",
      "tradeDateTime": "2026-04-17T10:01:00Z",
      "price": 200.0,
      "tradeQuantity": 5
    }
  |}
  in
  let e = Rest.bcs_trade_of_json j in
  Alcotest.(check bool) "side=2 parsed as Sell" true (e.side = Side.Sell);
  Alcotest.(check string)
    "ticker" "GAZP"
    (Ticker.to_string (Instrument.ticker e.instrument))

let test_decode_tolerant_numerics () =
  (* tradeQuantity is "double" in the doc but integer quantities
     may wire as plain [int]; price similarly sometimes comes as
     [int] for round values. Decoder must coerce both. *)
  let j =
    Yojson.Safe.from_string
      {|
    {
      "orderNum": 42,
      "tradeNum": 17,
      "ticker": "SBER", "classCode": "TQBR", "side": "1",
      "tradeQuantity": 7.0,
      "price": 200,
      "tradeDateTime": "2026-04-17T10:01:00Z"
    }
  |}
  in
  let e = Rest.bcs_trade_of_json j in
  Alcotest.(check (float 1e-6)) "quantity from float" 7.0 (Decimal.to_float e.quantity);
  Alcotest.(check (float 1e-6)) "price from int" 200.0 (Decimal.to_float e.price)

let test_orderNum_as_string () =
  (* Some gateway builds serialise int64 as a JSON string to avoid
     JS precision loss. The decoder accepts either form for both
     [orderNum] and [tradeNum]. *)
  let j =
    Yojson.Safe.from_string
      {|
    {
      "orderNum": "9999999999999",
      "tradeNum": "8888888888888",
      "ticker": "SBER", "classCode": "TQBR", "side": "1",
      "tradeQuantity": 1,
      "price": 100.0,
      "tradeDateTime": "2026-04-17T10:02:00Z"
    }
  |}
  in
  let e = Rest.bcs_trade_of_json j in
  Alcotest.(check string) "string orderNum preserved" "9999999999999" e.order_num;
  Alcotest.(check string) "string tradeNum preserved" "8888888888888" e.trade_id

let test_decode_records_list () =
  let j =
    Yojson.Safe.from_string
      (Printf.sprintf {| { "records": [ %s ], "totalRecords": 1, "totalPages": 1 } |}
         sample_deal)
  in
  let open Yojson.Safe.Util in
  let items =
    match member "records" j with
    | `List l -> List.map Rest.bcs_trade_of_json l
    | _ -> []
  in
  Alcotest.(check int) "1 record" 1 (List.length items);
  let e = List.hd items in
  Alcotest.(check string) "first orderNum" "1234567890" e.order_num

let test_doc_example_shape () =
  (* Exact payload from the BCS retail-API doc example. All numeric
     fields are [0] here — what we're verifying is that every field
     in the documented shape is accepted without error, and that
     millisecond-precision timestamps parse (the decoder drops sub-
     second precision by design — [Order.execution.ts] is epoch-seconds). *)
  let doc_payload =
    {|
    {
      "records": [
        {
          "orderNum": 0,
          "ticker": "string",
          "tradeNum": 0,
          "clientCode": "string",
          "classCode": "string",
          "settlementCurrency": "string",
          "baseCurrency": "string",
          "priceCurrency": "string",
          "side": "1",
          "instrumentType": "CURRENCY",
          "dealType": 0,
          "tradeDateTime": "2024-07-29T15:51:28.071Z",
          "price": 0,
          "volume": 0,
          "go": 0,
          "contractAmount": 0,
          "settleDate": "2024-07-29",
          "tradeQuantity": 0,
          "tradeQuantityLots": 0
        }
      ],
      "totalRecords": 0,
      "totalPages": 0
    }
  |}
  in
  let j = Yojson.Safe.from_string doc_payload in
  let open Yojson.Safe.Util in
  let items =
    match member "records" j with
    | `List l -> List.map Rest.bcs_trade_of_json l
    | _ -> []
  in
  Alcotest.(check int) "1 record parsed" 1 (List.length items);
  let e = List.hd items in
  Alcotest.(check string) "orderNum=0 stringified" "0" e.order_num;
  Alcotest.(check string) "tradeNum=0 stringified" "0" e.trade_id;
  (* 2024-07-29T15:51:28Z = 1722268288 unix seconds (fractional ms dropped). *)
  Alcotest.(check int64) "ts drops sub-second" 1722268288L e.ts

let test_filter_correlates_by_order_num () =
  (* Two fills for the same broker order + an unrelated one. The
     broker's [get_executions] first looks up the order's
     [exec_id], then runs exactly this filter. *)
  let mk order_num trade_id qty price : External_execution.t =
    {
      order_num;
      trade_id;
      instrument =
        Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ();
      side = Side.Buy;
      ts = 1L;
      quantity = Decimal.of_int qty;
      price = Decimal.of_float price;
      fee = Decimal.zero;
    }
  in
  let deals =
    [ mk "1001" "T1" 3 100.0; mk "1001" "T2" 7 101.0; mk "1002" "T3" 5 200.0 ]
  in
  let only_1001 =
    List.filter (fun (e : External_execution.t) -> e.order_num = "1001") deals
  in
  Alcotest.(check int) "2 fills for 1001" 2 (List.length only_1001);
  let total =
    List.fold_left
      (fun acc (e : External_execution.t) -> Decimal.add acc e.quantity)
      Decimal.zero only_1001
  in
  Alcotest.(check (float 1e-6)) "1001 totals 10" 10.0 (Decimal.to_float total)

let tests =
  [
    ("decode single deal", `Quick, test_decode_single_deal);
    ("decode sell side", `Quick, test_decode_sell_side);
    ("tolerant numeric types", `Quick, test_decode_tolerant_numerics);
    ("orderNum as string", `Quick, test_orderNum_as_string);
    ("decode records list", `Quick, test_decode_records_list);
    ("doc example shape", `Quick, test_doc_example_shape);
    ("filter by orderNum", `Quick, test_filter_correlates_by_order_num);
  ]

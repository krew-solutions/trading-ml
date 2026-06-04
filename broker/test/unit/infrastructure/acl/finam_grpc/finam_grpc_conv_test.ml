(** Unit tests for the Finam gRPC adapter's wire↔domain layer. Sociable: they
    exercise the real generated protobuf codec end-to-end (encode → bytes →
    decode) together with {!Finam_grpc.Conv} / {!Finam_grpc.Order_dto}, so a
    contract or conversion regression is caught without touching the network. *)

open Core
module G = Finam_grpc
module Conv = Finam_grpc.Conv
module Ord = Finam_grpc.Conv.Ord
module Md = Finam_grpc.Conv.Md
module Pbrt = Ocaml_protoc_plugin

let roundtrip_order_state (os : Ord.OrderState.t) : Ord.OrderState.t =
  Ord.OrderState.to_proto os |> Pbrt.Writer.contents |> Pbrt.Reader.create
  |> Ord.OrderState.from_proto_exn

(* ---- value-object converters ------------------------------------------ *)

let test_decimal () =
  Alcotest.(check (float 1e-9))
    "some" 1.5
    (Decimal.to_float (Conv.decimal_of_pb (Some "1.5")));
  Alcotest.(check (float 1e-9))
    "empty⇒0" 0.0
    (Decimal.to_float (Conv.decimal_of_pb (Some "")));
  Alcotest.(check (float 1e-9)) "none⇒0" 0.0 (Decimal.to_float (Conv.decimal_of_pb None));
  Alcotest.(check string) "to_pb" "2.5" (Conv.decimal_to_pb (Decimal.of_float 2.5))

let test_timestamp () =
  let ts = Conv.ts_of_pb (Some (Conv.ts_to_pb 1_700_000_000L)) in
  Alcotest.(check int64) "ts round-trip" 1_700_000_000L ts;
  Alcotest.(check int64) "none⇒0" 0L (Conv.ts_of_pb None)

let test_side () =
  Alcotest.(check bool) "buy" true (Conv.side_to_pb Buy = Conv.Pb_side.SIDE_BUY);
  Alcotest.(check bool) "sell" true (Conv.side_of_pb Conv.Pb_side.SIDE_SELL = Side.Sell);
  Alcotest.(check bool)
    "unspecified⇒none" true
    (Conv.side_of_pb_opt Conv.Pb_side.SIDE_UNSPECIFIED = None);
  Alcotest.(check bool)
    "buy aggressor" true
    (Conv.side_of_pb_opt Conv.Pb_side.SIDE_BUY = Some Side.Buy)

let test_timeframe () =
  Alcotest.(check bool) "M15" true (Conv.timeframe_to_pb M15 = Md.TimeFrame.TIME_FRAME_M15);
  Alcotest.(check bool) "H1" true (Conv.timeframe_to_pb H1 = Md.TimeFrame.TIME_FRAME_H1);
  Alcotest.(check bool) "D1" true (Conv.timeframe_to_pb D1 = Md.TimeFrame.TIME_FRAME_D)

let test_status () =
  Alcotest.(check string)
    "filled" "FILLED"
    (Order.status_to_string (Conv.status_of_pb Ord.OrderStatus.ORDER_STATUS_FILLED));
  Alcotest.(check string)
    "executed⇒filled" "FILLED"
    (Order.status_to_string (Conv.status_of_pb Ord.OrderStatus.ORDER_STATUS_EXECUTED));
  Alcotest.(check string)
    "rejected-by-exchange⇒rejected" "REJECTED"
    (Order.status_to_string
       (Conv.status_of_pb Ord.OrderStatus.ORDER_STATUS_REJECTED_BY_EXCHANGE))

(* ---- Bar → Candle ------------------------------------------------------ *)

let test_candle_of_bar () =
  let bar =
    Md.Bar.make
      ~timestamp:(Conv.ts_to_pb 1_700_000_000L)
      ~open':"100.0" ~high:"110.0" ~low:"99.0" ~close:"105.0" ~volume:"4200" ()
  in
  (* round-trip through the codec to prove decode too *)
  let bar =
    Md.Bar.to_proto bar |> Pbrt.Writer.contents |> Pbrt.Reader.create
    |> Md.Bar.from_proto_exn
  in
  let c = Conv.candle_of_bar bar in
  Alcotest.(check int64) "ts" 1_700_000_000L c.ts;
  Alcotest.(check (float 1e-9)) "open" 100.0 (Decimal.to_float c.open_);
  Alcotest.(check (float 1e-9)) "high" 110.0 (Decimal.to_float c.high);
  Alcotest.(check (float 1e-9)) "low" 99.0 (Decimal.to_float c.low);
  Alcotest.(check (float 1e-9)) "close" 105.0 (Decimal.to_float c.close);
  Alcotest.(check (float 1e-9)) "volume" 4200.0 (Decimal.to_float c.volume)

(* ---- PlaceOrder request building -------------------------------------- *)

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

let test_place_request_limit () =
  let o =
    G.Order_dto.place_request ~account_id:"ACC1" ~instrument:sber ~side:Buy
      ~quantity:(Decimal.of_int 10)
      ~kind:(Limit (Decimal.of_float 150.5))
      ~tif:DAY ~client_order_id:"coid-1"
  in
  let o =
    Ord.Order.to_proto o |> Pbrt.Writer.contents |> Pbrt.Reader.create
    |> Ord.Order.from_proto_exn
  in
  Alcotest.(check string) "symbol" "SBER@MISX" o.symbol;
  Alcotest.(check bool) "side" true (o.side = Conv.Pb_side.SIDE_BUY);
  Alcotest.(check bool) "type" true (o.type' = Ord.OrderType.ORDER_TYPE_LIMIT);
  Alcotest.(check bool) "tif" true (o.time_in_force = Ord.TimeInForce.TIME_IN_FORCE_DAY);
  Alcotest.(check (float 1e-9))
    "limit" 150.5
    (Decimal.to_float (Conv.decimal_of_pb o.limit_price));
  Alcotest.(check bool) "no stop" true (Conv.decimal_of_pb o.stop_price = Decimal.zero);
  Alcotest.(check string) "client_order_id" "coid-1" o.client_order_id

let test_place_request_market_has_no_prices () =
  let o =
    G.Order_dto.place_request ~account_id:"ACC1" ~instrument:sber ~side:Sell
      ~quantity:(Decimal.of_int 5) ~kind:Market ~tif:IOC ~client_order_id:"x"
  in
  Alcotest.(check bool) "no limit" true (o.limit_price = None);
  Alcotest.(check bool) "no stop" true (o.stop_price = None);
  Alcotest.(check bool) "type market" true (o.type' = Ord.OrderType.ORDER_TYPE_MARKET)

(* ---- OrderState → domain ---------------------------------------------- *)

let test_decode_order_state () =
  let os =
    Ord.OrderState.make ~order_id:"12345678" ~exec_id:"exec-001"
      ~status:Ord.OrderStatus.ORDER_STATUS_PARTIALLY_FILLED
      ~order:
        (Ord.Order.make ~account_id:"ACC1" ~symbol:"SBER@MISX" ~side:Conv.Pb_side.SIDE_BUY
           ~type':Ord.OrderType.ORDER_TYPE_LIMIT
           ~time_in_force:Ord.TimeInForce.TIME_IN_FORCE_DAY ~limit_price:"150.5"
           ~client_order_id:"coid-abc" ())
      ~transact_at:(Conv.ts_to_pb 1_700_000_000L)
      ~initial_quantity:"10" ~executed_quantity:"6" ()
  in
  let d = G.Order_dto.of_pb (roundtrip_order_state os) in
  Alcotest.(check string) "order_id" "12345678" d.order_id;
  Alcotest.(check string) "exec_id" "exec-001" d.exec_id;
  Alcotest.(check string) "client_order_id" "coid-abc" d.client_order_id;
  Alcotest.(check string) "status" "PARTIALLY_FILLED" (Order.status_to_string d.status);
  Alcotest.(check string) "side" "BUY" (Side.to_string d.side);
  Alcotest.(check string)
    "instrument ticker" "SBER"
    (Ticker.to_string (Instrument.ticker d.instrument));
  Alcotest.(check (float 1e-9)) "quantity" 10.0 (Decimal.to_float d.quantity);
  Alcotest.(check (float 1e-9)) "filled" 6.0 (Decimal.to_float d.filled);
  Alcotest.(check string) "kind" "LIMIT" (Order.kind_to_string d.kind);
  Alcotest.(check int64) "placed_ts" 1_700_000_000L d.placed_ts;
  let dom = G.Order_dto.to_domain ~placement_id:7 d in
  Alcotest.(check int) "placement_id" 7 dom.placement_id

(* ---- placement handle store ------------------------------------------- *)

let test_placement_store () =
  let s = G.Placement_handle_store.create () in
  Alcotest.(check bool)
    "first record ok" true
    (G.Placement_handle_store.record s ~placement_id:1 ~client_order_id:"c1" = `Ok);
  Alcotest.(check bool)
    "dup placement" true
    (G.Placement_handle_store.record s ~placement_id:1 ~client_order_id:"c2"
    = `Already_exists);
  Alcotest.(check (option string))
    "forward" (Some "c1")
    (G.Placement_handle_store.find_client_order_id s ~placement_id:1);
  Alcotest.(check (option int))
    "reverse" (Some 1)
    (G.Placement_handle_store.find_placement_id s ~client_order_id:"c1");
  Alcotest.(check (option int))
    "unknown reverse" None
    (G.Placement_handle_store.find_placement_id s ~client_order_id:"nope")

let tests =
  [
    ("decimal conv", `Quick, test_decimal);
    ("timestamp conv", `Quick, test_timestamp);
    ("side conv", `Quick, test_side);
    ("timeframe conv", `Quick, test_timeframe);
    ("status conv", `Quick, test_status);
    ("bar → candle", `Quick, test_candle_of_bar);
    ("place request (limit)", `Quick, test_place_request_limit);
    ("place request (market, no prices)", `Quick, test_place_request_market_has_no_prices);
    ("decode order state → domain", `Quick, test_decode_order_state);
    ("placement handle store", `Quick, test_placement_store);
  ]

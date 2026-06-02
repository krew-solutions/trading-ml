(** Unit tests for [Alor.Ws]: the channel-agnostic frame split (data
    vs control) and the subscribe / unsubscribe request encoders. *)

open Core
open Alor

let cfg = Config.make ~refresh_token:"R" ~portfolio:"D12345" ()

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX")
    ~board:(Board.of_string "TQBR") ()

let test_frame_data () =
  match
    Ws.frame_of_json
      (Yojson.Safe.from_string {|{"data":{"time":1,"close":2},"guid":"g1"}|})
  with
  | Some { guid; data } ->
      Alcotest.(check string) "guid" "g1" guid;
      Alcotest.(check bool)
        "data carries time" true
        (Yojson.Safe.Util.member "time" data <> `Null)
  | None -> Alcotest.fail "expected a data frame"

let test_frame_control_is_none () =
  let control = {|{"requestGuid":"g1","httpCode":200,"message":"ok"}|} in
  Alcotest.(check bool)
    "control frame → None" true
    (Ws.frame_of_json (Yojson.Safe.from_string control) = None);
  Alcotest.(check bool)
    "data without guid → None" true
    (Ws.frame_of_json (Yojson.Safe.from_string {|{"data":{"x":1}}|}) = None)

let member j k = Yojson.Safe.Util.member k j

let test_bars_subscribe_envelope () =
  let j =
    Ws.Requests.Bars.subscribe ~cfg ~token:"JWT" ~guid:"g1" ~instrument:sber ~timeframe:H1
      ()
  in
  let str k = Yojson.Safe.Util.to_string (member j k) in
  Alcotest.(check string) "opcode" "BarsGetAndSubscribe" (str "opcode");
  Alcotest.(check string) "code (bare ticker)" "SBER" (str "code");
  Alcotest.(check string) "exchange" "MOEX" (str "exchange");
  Alcotest.(check string) "instrumentGroup" "TQBR" (str "instrumentGroup");
  Alcotest.(check string) "token" "JWT" (str "token");
  Alcotest.(check string) "guid" "g1" (str "guid");
  Alcotest.(check string) "tf is string \"3600\"" "3600" (str "tf")

let test_trades_subscribe_envelope () =
  let j = Ws.Requests.Trades.subscribe ~cfg ~token:"JWT" ~guid:"g2" () in
  let str k = Yojson.Safe.Util.to_string (member j k) in
  Alcotest.(check string) "opcode" "TradesGetAndSubscribeV2" (str "opcode");
  Alcotest.(check string) "exchange default" "MOEX" (str "exchange");
  Alcotest.(check string) "portfolio" "D12345" (str "portfolio");
  Alcotest.(check string) "guid" "g2" (str "guid")

let test_unsubscribe_envelope () =
  let j = Ws.Requests.Unsubscribe.make ~token:"JWT" ~guid:"g3" in
  let str k = Yojson.Safe.Util.to_string (member j k) in
  Alcotest.(check string) "opcode" "unsubscribe" (str "opcode");
  Alcotest.(check string) "guid" "g3" (str "guid")

let test_public_trades_subscribe_envelope () =
  let j =
    Ws.Requests.Public_trades.subscribe ~cfg ~token:"JWT" ~guid:"g4" ~instrument:sber ()
  in
  let str k = Yojson.Safe.Util.to_string (member j k) in
  Alcotest.(check string) "opcode" "AllTradesGetAndSubscribe" (str "opcode");
  Alcotest.(check string) "code (bare ticker)" "SBER" (str "code");
  Alcotest.(check string) "exchange" "MOEX" (str "exchange");
  Alcotest.(check string) "instrumentGroup" "TQBR" (str "instrumentGroup");
  Alcotest.(check string) "guid" "g4" (str "guid");
  Alcotest.(check int)
    "depth=0 (live tape, no history)" 0
    (match member j "depth" with
    | `Int n -> n
    | _ -> -1);
  Alcotest.(check bool)
    "includeVirtualTrades=false" false
    (match member j "includeVirtualTrades" with
    | `Bool b -> b
    | _ -> true)

(* AllTradesGetAndSubscribe data frame in the "Simple" format the bridge
   subscribes with: it carries NO [exchange] field (only symbol/qty/price/
   side/timestamp), which is exactly why the instrument must come from the
   subscription, not from the frame — reconstructing it would default the
   venue to the XXXX placeholder. *)
let trade_data side =
  Yojson.Safe.from_string
    (Printf.sprintf
       {|{"symbol":"SBER","qty":7,"price":250.5,"side":"%s","timestamp":1716800000000}|}
       side)

let test_decode_public_trade_buy () =
  let pt = Ws.Events.Public_trades.parse ~instrument:sber (trade_data "buy") in
  Alcotest.(check bool) "side = Buy" true (pt.side = Some Side.Buy);
  Alcotest.(check (float 1e-6)) "qty" 7.0 (Decimal.to_float pt.quantity);
  Alcotest.(check (float 1e-6)) "price" 250.5 (Decimal.to_float pt.price);
  (* Instrument is the subscribed one verbatim — venue MISX, not the XXXX
     placeholder a frame-only reconstruction would yield. *)
  Alcotest.(check string)
    "instrument is the subscribed one" "SBER@MISX/TQBR"
    (Instrument.to_qualified pt.instrument);
  Alcotest.(check bool) "timestamp carried" true (pt.ts = 1716800000000L)

let test_decode_public_trade_sell () =
  let pt = Ws.Events.Public_trades.parse ~instrument:sber (trade_data "sell") in
  Alcotest.(check bool) "side = Sell" true (pt.side = Some Side.Sell)

let test_decode_public_trade_unmarked_has_no_side () =
  (* The public tape must not fabricate a side for an unmarked print. *)
  let pt = Ws.Events.Public_trades.parse ~instrument:sber (trade_data "") in
  Alcotest.(check bool) "side = None" true (pt.side = None)

let tests =
  [
    ("frame: data", `Quick, test_frame_data);
    ("frame: control → None", `Quick, test_frame_control_is_none);
    ("bars subscribe envelope", `Quick, test_bars_subscribe_envelope);
    ("trades subscribe envelope", `Quick, test_trades_subscribe_envelope);
    ("unsubscribe envelope", `Quick, test_unsubscribe_envelope);
    ("public-trades subscribe envelope", `Quick, test_public_trades_subscribe_envelope);
    ("decode public trade — buy aggressor", `Quick, test_decode_public_trade_buy);
    ("decode public trade — sell aggressor", `Quick, test_decode_public_trade_sell);
    ( "decode public trade — unmarked has no side",
      `Quick,
      test_decode_public_trade_unmarked_has_no_side );
  ]

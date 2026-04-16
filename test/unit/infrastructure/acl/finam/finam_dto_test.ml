open Core

let test_candle_parse () =
  let j = Yojson.Safe.from_string {|
    { "timestamp": "2024-01-02T10:30:00Z",
      "open": "100.5", "high": "101.0",
      "low": "100.0", "close": "100.75",
      "volume": "1234" } |}
  in
  let c = Finam.Dto.candle_of_json j in
  Alcotest.(check (float 1e-6)) "open"
    100.5 (Decimal.to_float c.Candle.open_);
  Alcotest.(check (float 1e-6)) "close"
    100.75 (Decimal.to_float c.Candle.close);
  Alcotest.(check bool) "ts > 0" true (Int64.compare c.ts 0L > 0)

let test_candles_list () =
  let j = Yojson.Safe.from_string {|
    { "bars": [
        {"timestamp":"2024-01-01T00:00:00Z","open":"1","high":"2","low":"0.5","close":"1.5","volume":"10"},
        {"timestamp":"2024-01-01T00:01:00Z","open":"1.5","high":"2","low":"1","close":"1.8","volume":"15"}
      ]} |}
  in
  let cs = Finam.Dto.candles_of_json j in
  Alcotest.(check int) "2 bars" 2 (List.length cs)

let tests = [
  "candle parse", `Quick, test_candle_parse;
  "candles list", `Quick, test_candles_list;
]

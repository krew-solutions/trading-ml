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

(** Sample [GetAssetResponse] payload, mirroring the proto shape from
    [proto/grpc/tradeapi/v1/assets/assets_service.proto]. Field set:
    board, id, ticker, mic, isin, type, name, decimals, min_step,
    lot_size, quote_currency. *)
let asset_sber_json = {|
  { "board": "TQBR",
    "id": "12345",
    "ticker": "SBER",
    "mic": "MISX",
    "isin": "RU0009029540",
    "type": "EQUITIES",
    "name": "Сбербанк",
    "decimals": 2,
    "min_step": 1,
    "lot_size": "10",
    "quote_currency": "RUB" }
|}

let test_asset_full () =
  let i = Finam.Dto.instrument_of_asset_json
    (Yojson.Safe.from_string asset_sber_json) in
  Alcotest.(check string) "ticker" "SBER"
    (Ticker.to_string (Instrument.ticker i));
  Alcotest.(check string) "mic" "MISX"
    (Mic.to_string (Instrument.venue i));
  Alcotest.(check (option string)) "isin"
    (Some "RU0009029540")
    (Option.map Isin.to_string (Instrument.isin i));
  Alcotest.(check (option string)) "board"
    (Some "TQBR")
    (Option.map Board.to_string (Instrument.board i))

let test_asset_no_isin () =
  (* Futures often lack ISIN — must still decode. *)
  let j = Yojson.Safe.from_string {|
    { "board": "SPBFUT", "ticker": "SiZ5", "mic": "RTSX",
      "isin": "", "type": "FUTURES", "name": "Si-12.25" } |} in
  let i = Finam.Dto.instrument_of_asset_json j in
  Alcotest.(check (option string)) "no isin" None
    (Option.map Isin.to_string (Instrument.isin i));
  Alcotest.(check (option string)) "board still set"
    (Some "SPBFUT")
    (Option.map Board.to_string (Instrument.board i))

let test_asset_drops_invalid_isin () =
  (* Tampered checksum → drop silently, instrument still usable. *)
  let j = Yojson.Safe.from_string {|
    { "board": "TQBR", "ticker": "X", "mic": "MISX",
      "isin": "RU0009029541" } |} in
  let i = Finam.Dto.instrument_of_asset_json j in
  Alcotest.(check (option string)) "bad isin dropped" None
    (Option.map Isin.to_string (Instrument.isin i))

let tests = [
  "candle parse",            `Quick, test_candle_parse;
  "candles list",            `Quick, test_candles_list;
  "asset full",              `Quick, test_asset_full;
  "asset without isin",      `Quick, test_asset_no_isin;
  "asset drops invalid isin",`Quick, test_asset_drops_invalid_isin;
]

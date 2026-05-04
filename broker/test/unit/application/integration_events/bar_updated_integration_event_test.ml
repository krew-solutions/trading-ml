(** Unit tests for {!Broker_integration_events.Bar_updated_integration_event}.

    Pin field-by-field correspondence between domain values and the DTO,
    so a future rename or representation change in [Candle_view_model] /
    [Instrument_view_model] / [Timeframe.to_string] is caught here rather
    than at the wire boundary. *)

open Core

module Event = Broker_integration_events.Bar_updated_integration_event

let sample_instrument () =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

let sample_candle () =
  Candle.make ~ts:1_700_000_000L ~open_:(Decimal.of_string "100.5")
    ~high:(Decimal.of_string "101.0") ~low:(Decimal.of_string "100.0")
    ~close:(Decimal.of_string "100.75") ~volume:(Decimal.of_string "1234")

let test_of_domain_maps_all_fields () =
  let instrument = sample_instrument () in
  let bar = sample_candle () in
  let timeframe = Timeframe.H1 in
  let dto = Event.of_domain ~instrument ~timeframe ~bar in
  Alcotest.(check string) "ticker" "SBER" dto.instrument.ticker;
  Alcotest.(check string) "venue" "MISX" dto.instrument.venue;
  Alcotest.(check (option string)) "isin absent" None dto.instrument.isin;
  Alcotest.(check (option string)) "board absent" None dto.instrument.board;
  Alcotest.(check string) "timeframe" (Timeframe.to_string Timeframe.H1) dto.timeframe;
  Alcotest.(check int64) "ts" 1_700_000_000L dto.bar.ts;
  (* Wire format strips trailing zeros via [Decimal.to_string] —
     "101.0" becomes "101". Pinning the normalized form here so a
     change to the decimal serializer surfaces as a test failure
     rather than as a silent contract drift. *)
  Alcotest.(check string) "open" "100.5" dto.bar.open_;
  Alcotest.(check string) "high" "101" dto.bar.high;
  Alcotest.(check string) "low" "100" dto.bar.low;
  Alcotest.(check string) "close" "100.75" dto.bar.close;
  Alcotest.(check string) "volume" "1234" dto.bar.volume

let test_yojson_roundtrip () =
  let instrument = sample_instrument () in
  let bar = sample_candle () in
  let dto = Event.of_domain ~instrument ~timeframe:Timeframe.M5 ~bar in
  let restored = Event.t_of_yojson (Event.yojson_of_t dto) in
  Alcotest.(check string) "ticker" dto.instrument.ticker restored.instrument.ticker;
  Alcotest.(check string) "venue" dto.instrument.venue restored.instrument.venue;
  Alcotest.(check string) "timeframe" dto.timeframe restored.timeframe;
  Alcotest.(check int64) "ts" dto.bar.ts restored.bar.ts;
  Alcotest.(check string) "close" dto.bar.close restored.bar.close

let tests =
  [
    ("of_domain maps all fields", `Quick, test_of_domain_maps_all_fields);
    ("yojson roundtrip", `Quick, test_yojson_roundtrip);
  ]

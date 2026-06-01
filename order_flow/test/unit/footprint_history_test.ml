(** Unit tests for the [GET /api/footprints] read-model
    ({!Order_flow_inbound_http.Footprint_history}): per-(instrument,
    boundary) keying, oldest-first windowing, the per-key cap, and the
    idempotent head-replace on redelivery. *)

module History = Order_flow_inbound_http.Footprint_history
module FC = Order_flow_integration_events.Footprint_completed_integration_event
module Instrument_vm = Order_flow_view_models.Instrument_view_model

let instrument ?board ~ticker ~venue () : Instrument_vm.t =
  { ticker; venue; isin = None; board }

(* A footprint fact is identified for these tests by its key fields +
   open_ts; the OHLCV/delta payload is irrelevant to history behaviour,
   so it is filled with a constant. *)
let fp ?board ~ticker ~venue ~timeframe ~open_ts () : FC.t =
  {
    instrument = instrument ?board ~ticker ~venue ();
    timeframe;
    open_ts;
    open_price = "100";
    high = "101";
    low = "99";
    close = "100";
    volume = "10";
    delta = "0";
    poc_price = "100";
    clusters = [];
  }

let open_ts_list xs = List.map (fun (f : FC.t) -> f.FC.open_ts) xs

let test_recent_oldest_first () =
  let h = History.create () in
  List.iter (History.record h)
    [
      fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t1" ();
      fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t2" ();
      fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t3" ();
    ];
  let got = History.recent h ~symbol:"SBER@MISX" ~timeframe:"M5" ~n:10 in
  Alcotest.(check (list string)) "oldest-first" [ "t1"; "t2"; "t3" ] (open_ts_list got)

let test_recent_caps_to_n () =
  let h = History.create () in
  List.iter
    (fun i ->
      History.record h
        (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5"
           ~open_ts:("t" ^ string_of_int i)
           ()))
    [ 1; 2; 3; 4; 5 ];
  (* last 2, oldest-first *)
  let got = History.recent h ~symbol:"SBER@MISX" ~timeframe:"M5" ~n:2 in
  Alcotest.(check (list string)) "last n, oldest-first" [ "t4"; "t5" ] (open_ts_list got)

let test_key_separates_instrument_and_boundary () =
  let h = History.create () in
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"a" ());
  History.record h (fp ~ticker:"GAZP" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"b" ());
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M1" ~open_ts:"c" ());
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"VOL:1000" ~open_ts:"d" ());
  let one sym tf = open_ts_list (History.recent h ~symbol:sym ~timeframe:tf ~n:10) in
  Alcotest.(check (list string)) "SBER M5 only" [ "a" ] (one "SBER@MISX" "M5");
  Alcotest.(check (list string)) "GAZP M5 only" [ "b" ] (one "GAZP@MISX" "M5");
  Alcotest.(check (list string)) "SBER M1 only" [ "c" ] (one "SBER@MISX" "M1");
  Alcotest.(check (list string)) "SBER Volume only" [ "d" ] (one "SBER@MISX" "VOL:1000")

let test_board_in_key () =
  let h = History.create () in
  History.record h
    (fp ~board:"TQBR" ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"x" ());
  Alcotest.(check (list string))
    "qualified key includes board" [ "x" ]
    (open_ts_list (History.recent h ~symbol:"SBER@MISX/TQBR" ~timeframe:"M5" ~n:10));
  Alcotest.(check (list string))
    "board-less symbol does not match" []
    (open_ts_list (History.recent h ~symbol:"SBER@MISX" ~timeframe:"M5" ~n:10))

let test_idempotent_head_replace () =
  let h = History.create () in
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t1" ());
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t2" ());
  (* redelivery of the latest open_ts must not double the head *)
  History.record h (fp ~ticker:"SBER" ~venue:"MISX" ~timeframe:"M5" ~open_ts:"t2" ());
  let got = History.recent h ~symbol:"SBER@MISX" ~timeframe:"M5" ~n:10 in
  Alcotest.(check (list string)) "no duplicate head" [ "t1"; "t2" ] (open_ts_list got)

let test_unknown_key_empty () =
  let h = History.create () in
  Alcotest.(check (list string))
    "unknown key -> empty" []
    (open_ts_list (History.recent h ~symbol:"NOPE@MISX" ~timeframe:"M5" ~n:10))

let tests =
  [
    Alcotest.test_case "recent is oldest-first" `Quick test_recent_oldest_first;
    Alcotest.test_case "recent caps to n (last n)" `Quick test_recent_caps_to_n;
    Alcotest.test_case "key separates instrument and boundary" `Quick
      test_key_separates_instrument_and_boundary;
    Alcotest.test_case "board is part of the key" `Quick test_board_in_key;
    Alcotest.test_case "idempotent head replace on redelivery" `Quick
      test_idempotent_head_replace;
    Alcotest.test_case "unknown key returns empty" `Quick test_unknown_key_empty;
  ]

open Core

let sber_isin = "RU0009029540"

let mk ?isin ?board ticker mic =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string mic)
    ?isin:(Option.map Isin.of_string isin)
    ?board:(Option.map Board.of_string board)
    ()

let test_make_minimal () =
  let i = mk "SBER" "MISX" in
  Alcotest.(check string) "ticker" "SBER" (Ticker.to_string (Instrument.ticker i));
  Alcotest.(check string) "venue" "MISX" (Mic.to_string (Instrument.venue i));
  Alcotest.(check bool) "no isin" true (Instrument.isin i = None);
  Alcotest.(check bool) "no board" true (Instrument.board i = None)

let test_make_enriched () =
  let i = mk ~isin:sber_isin ~board:"TQBR" "SBER" "MISX" in
  Alcotest.(check (option string))
    "isin" (Some sber_isin)
    (Option.map Isin.to_string (Instrument.isin i));
  Alcotest.(check (option string))
    "board" (Some "TQBR")
    (Option.map Board.to_string (Instrument.board i))

let test_equal_by_isin () =
  (* Same ISIN+MIC, different boards → still equal (board not in ID). *)
  let a = mk ~isin:sber_isin ~board:"TQBR" "SBER" "MISX" in
  let b = mk ~isin:sber_isin ~board:"SMAL" "SBER" "MISX" in
  Alcotest.(check bool) "same ISIN+MIC, diff boards = equal" true (Instrument.equal a b)

let test_equal_by_ticker_when_no_isin () =
  let a = mk "SBER" "MISX" in
  let b = mk ~board:"TQBR" "SBER" "MISX" in
  Alcotest.(check bool)
    "no ISINs, same Ticker+MIC, diff boards = equal" true (Instrument.equal a b)

let test_not_equal_diff_venue () =
  let a = mk ~isin:sber_isin "SBER" "MISX" in
  let b = mk ~isin:sber_isin "SBER" "IEXG" in
  Alcotest.(check bool) "different MIC = not equal" false (Instrument.equal a b)

let test_not_equal_one_isin_one_not () =
  let a = mk ~isin:sber_isin "SBER" "MISX" in
  let b = mk "SBER" "MISX" in
  Alcotest.(check bool) "ISIN vs no-ISIN = not equal" false (Instrument.equal a b)

let test_qualified_minimal () =
  let i = mk "SBER" "MISX" in
  Alcotest.(check string) "ticker@mic" "SBER@MISX" (Instrument.to_qualified i)

let test_qualified_with_board () =
  let i = mk ~board:"TQBR" "SBER" "MISX" in
  Alcotest.(check string) "ticker@mic/board" "SBER@MISX/TQBR" (Instrument.to_qualified i)

let test_of_qualified_minimal () =
  let i = Instrument.of_qualified "SBER@MISX" in
  Alcotest.(check bool) "round-trip" true (Instrument.equal i (mk "SBER" "MISX"))

let test_of_qualified_with_board () =
  let i = Instrument.of_qualified "SBER@MISX/TQBR" in
  Alcotest.(check (option string))
    "board parsed" (Some "TQBR")
    (Option.map Board.to_string (Instrument.board i));
  Alcotest.(check string) "venue parsed" "MISX" (Mic.to_string (Instrument.venue i))

let test_of_qualified_with_isin () =
  let s = "SBER@MISX/TQBR?isin=" ^ sber_isin in
  let i = Instrument.of_qualified s in
  Alcotest.(check (option string))
    "isin parsed" (Some sber_isin)
    (Option.map Isin.to_string (Instrument.isin i))

let test_of_qualified_rejects_bare_ticker () =
  Alcotest.check_raises "no @MIC"
    (Invalid_argument "Instrument.of_qualified: missing @MIC in SBER") (fun () ->
      ignore (Instrument.of_qualified "SBER"))

let tests =
  [
    ("make minimal", `Quick, test_make_minimal);
    ("make enriched", `Quick, test_make_enriched);
    ("equal by ISIN ignores board", `Quick, test_equal_by_isin);
    ("equal by ticker when no ISIN", `Quick, test_equal_by_ticker_when_no_isin);
    ("different venue is not equal", `Quick, test_not_equal_diff_venue);
    ("ISIN vs no-ISIN is not equal", `Quick, test_not_equal_one_isin_one_not);
    ("to_qualified minimal", `Quick, test_qualified_minimal);
    ("to_qualified with board", `Quick, test_qualified_with_board);
    ("of_qualified minimal", `Quick, test_of_qualified_minimal);
    ("of_qualified with board", `Quick, test_of_qualified_with_board);
    ("of_qualified with ?isin=", `Quick, test_of_qualified_with_isin);
    ("of_qualified rejects bare", `Quick, test_of_qualified_rejects_bare_ticker);
  ]

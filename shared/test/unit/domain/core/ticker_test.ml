open Core

let test_valid () =
  Alcotest.(check string)
    "round-trips upper" "SBER"
    (Ticker.to_string (Ticker.of_string "SBER"));
  Alcotest.(check string)
    "uppercases lowercase" "AAPL"
    (Ticker.to_string (Ticker.of_string "aapl"))

let test_trims () =
  Alcotest.(check string)
    "trims whitespace around" "GAZP"
    (Ticker.to_string (Ticker.of_string "  gazp  "))

let test_rejects_empty () =
  Alcotest.check_raises "empty" (Invalid_argument "Ticker.of_string: empty") (fun () ->
      ignore (Ticker.of_string ""));
  Alcotest.check_raises "all whitespace" (Invalid_argument "Ticker.of_string: empty")
    (fun () -> ignore (Ticker.of_string "   "))

let test_rejects_inner_whitespace () =
  Alcotest.check_raises "inner space"
    (Invalid_argument "Ticker.of_string: \"SB ER\" — whitespace") (fun () ->
      ignore (Ticker.of_string "SB ER"))

let tests =
  [
    ("valid round-trip", `Quick, test_valid);
    ("trims outer whitespace", `Quick, test_trims);
    ("rejects empty", `Quick, test_rejects_empty);
    ("rejects inner ws", `Quick, test_rejects_inner_whitespace);
  ]

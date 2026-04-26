open Core

let test_valid () =
  let m = Mic.of_string "MISX" in
  Alcotest.(check string) "round-trips" "MISX" (Mic.to_string m)

let test_normalises () =
  Alcotest.(check string)
    "trims + uppercases" "XNYS"
    (Mic.to_string (Mic.of_string "  xnys  "));
  Alcotest.(check string) "uppercases mixed" "MISX" (Mic.to_string (Mic.of_string "MiSx"))

let test_rejects_wrong_length () =
  Alcotest.check_raises "too short"
    (Invalid_argument "Mic.of_string: \"ABC\" — expected 4 chars") (fun () ->
      ignore (Mic.of_string "ABC"));
  Alcotest.check_raises "too long"
    (Invalid_argument "Mic.of_string: \"ABCDE\" — expected 4 chars") (fun () ->
      ignore (Mic.of_string "ABCDE"))

let test_rejects_non_alnum () =
  Alcotest.check_raises "punctuation"
    (Invalid_argument "Mic.of_string: \"AB-D\" — non-alphanumeric") (fun () ->
      ignore (Mic.of_string "AB-D"))

let test_equal () =
  Alcotest.(check bool)
    "case-insensitive equality" true
    (Mic.equal (Mic.of_string "misx") (Mic.of_string "MISX"))

let tests =
  [
    ("valid round-trip", `Quick, test_valid);
    ("normalises whitespace", `Quick, test_normalises);
    ("rejects wrong length", `Quick, test_rejects_wrong_length);
    ("rejects non-alphanumeric", `Quick, test_rejects_non_alnum);
    ("equality", `Quick, test_equal);
  ]

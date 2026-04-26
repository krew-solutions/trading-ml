open Core

(** Sample valid ISINs from the wild. Sberbank common share, Apple
    common share. Both verified against published checksum. *)
let sber_isin = "RU0009029540"

let aapl_isin = "US0378331005"

let test_valid_known () =
  Alcotest.(check string)
    "SBER round-trips" sber_isin
    (Isin.to_string (Isin.of_string sber_isin));
  Alcotest.(check string)
    "AAPL round-trips" aapl_isin
    (Isin.to_string (Isin.of_string aapl_isin))

let test_normalises () =
  Alcotest.(check string)
    "lowercases accepted, upper-cased back" sber_isin
    (Isin.to_string (Isin.of_string (String.lowercase_ascii sber_isin)))

let test_rejects_wrong_length () =
  Alcotest.check_raises "11 chars"
    (Invalid_argument "Isin.of_string: \"RU000902954\" — expected 12 chars") (fun () ->
      ignore (Isin.of_string "RU000902954"))

let test_rejects_bad_checksum () =
  (* Tamper with the last digit. *)
  let bad = "RU0009029541" in
  Alcotest.check_raises "bad checksum"
    (Invalid_argument (Printf.sprintf "Isin.of_string: %S — bad checksum" bad))
    (fun () -> ignore (Isin.of_string bad))

let test_rejects_non_alnum () =
  Alcotest.check_raises "punctuation"
    (Invalid_argument "Isin.of_string: \"RU000902-540\" — non-alphanumeric") (fun () ->
      ignore (Isin.of_string "RU000902-540"))

let tests =
  [
    ("valid known ISINs", `Quick, test_valid_known);
    ("normalises case", `Quick, test_normalises);
    ("rejects wrong length", `Quick, test_rejects_wrong_length);
    ("rejects bad checksum", `Quick, test_rejects_bad_checksum);
    ("rejects non-alnum", `Quick, test_rejects_non_alnum);
  ]

open Core

let test_valid () =
  Alcotest.(check string) "TQBR" "TQBR" (Board.to_string (Board.of_string "TQBR"));
  Alcotest.(check string) "SPBFUT" "SPBFUT" (Board.to_string (Board.of_string "spbfut"))

let test_rejects_empty () =
  Alcotest.check_raises "empty" (Invalid_argument "Board.of_string: empty") (fun () ->
      ignore (Board.of_string ""))

let test_rejects_whitespace () =
  Alcotest.check_raises "inner ws"
    (Invalid_argument "Board.of_string: \"TQ BR\" — whitespace") (fun () ->
      ignore (Board.of_string "TQ BR"))

let tests =
  [
    ("valid round-trip", `Quick, test_valid);
    ("rejects empty", `Quick, test_rejects_empty);
    ("rejects whitespace", `Quick, test_rejects_whitespace);
  ]

open Core

let d = Decimal.of_float

let eq_dec x y =
  Float.abs (Decimal.to_float x -. Decimal.to_float y) < 1e-6

let test_zero () =
  Alcotest.(check bool) "zero" true (Decimal.is_zero Decimal.zero);
  Alcotest.(check bool) "one positive" true (Decimal.is_positive Decimal.one)

let test_roundtrip () =
  List.iter (fun f ->
    let x = Decimal.of_float f in
    Alcotest.(check (float 1e-6)) "roundtrip" f (Decimal.to_float x)
  ) [0.0; 1.0; -1.5; 123.456789; 1000.0]

let test_string_roundtrip () =
  List.iter (fun s ->
    let x = Decimal.of_string s in
    let s' = Decimal.to_string x in
    let x' = Decimal.of_string s' in
    Alcotest.(check bool) ("string: " ^ s) true (Decimal.equal x x')
  ) ["0"; "1"; "-1.5"; "123.45"; "0.00000001"]

let test_arithmetic () =
  Alcotest.(check bool) "1+1" true
    (eq_dec (Decimal.add (d 1.0) (d 1.0)) (d 2.0));
  Alcotest.(check bool) "3-1" true
    (eq_dec (Decimal.sub (d 3.0) (d 1.0)) (d 2.0));
  Alcotest.(check bool) "2*3" true
    (eq_dec (Decimal.mul (d 2.0) (d 3.0)) (d 6.0));
  Alcotest.(check bool) "6/2" true
    (eq_dec (Decimal.div (d 6.0) (d 2.0)) (d 3.0))

let test_div_by_zero () =
  Alcotest.check_raises "div by zero" Division_by_zero
    (fun () -> ignore (Decimal.div (d 1.0) Decimal.zero))

let qcheck_add_commutative =
  QCheck.Test.make ~name:"add commutative" ~count:500
    QCheck.(pair (float_range (-1e6) 1e6) (float_range (-1e6) 1e6))
    (fun (a, b) -> eq_dec (Decimal.add (d a) (d b)) (Decimal.add (d b) (d a)))

let tests = [
  "zero", `Quick, test_zero;
  "roundtrip float", `Quick, test_roundtrip;
  "roundtrip string", `Quick, test_string_roundtrip;
  "arithmetic", `Quick, test_arithmetic;
  "div by zero", `Quick, test_div_by_zero;
  "add commutative", `Quick,
    (fun () -> QCheck.Test.check_exn qcheck_add_commutative);
]

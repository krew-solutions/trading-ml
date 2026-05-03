let d = Decimal.of_float

let eq_dec x y = Float.abs (Decimal.to_float x -. Decimal.to_float y) < 1e-6

(** Exact decimal-string equality. {!eq_dec} compares floats with 1e-6
    tolerance, which silently masks precision loss above 2^53. The
    overflow tests below need bit-exact comparison. *)
let dec_eq label expected actual =
  Alcotest.(check string) label (Decimal.to_string expected) (Decimal.to_string actual)

let test_zero () =
  Alcotest.(check bool) "zero" true (Decimal.is_zero Decimal.zero);
  Alcotest.(check bool) "one positive" true (Decimal.is_positive Decimal.one)

let test_roundtrip () =
  List.iter
    (fun f ->
      let x = Decimal.of_float f in
      Alcotest.(check (float 1e-6)) "roundtrip" f (Decimal.to_float x))
    [ 0.0; 1.0; -1.5; 123.456789; 1000.0 ]

let test_string_roundtrip () =
  List.iter
    (fun s ->
      let x = Decimal.of_string s in
      let s' = Decimal.to_string x in
      let x' = Decimal.of_string s' in
      Alcotest.(check bool) ("string: " ^ s) true (Decimal.equal x x'))
    [ "0"; "1"; "-1.5"; "123.45"; "0.00000001" ]

let test_arithmetic () =
  Alcotest.(check bool) "1+1" true (eq_dec (Decimal.add (d 1.0) (d 1.0)) (d 2.0));
  Alcotest.(check bool) "3-1" true (eq_dec (Decimal.sub (d 3.0) (d 1.0)) (d 2.0));
  Alcotest.(check bool) "2*3" true (eq_dec (Decimal.mul (d 2.0) (d 3.0)) (d 6.0));
  Alcotest.(check bool) "6/2" true (eq_dec (Decimal.div (d 6.0) (d 2.0)) (d 3.0))

let test_div_by_zero () =
  Alcotest.check_raises "div by zero" Division_by_zero (fun () ->
      ignore (Decimal.div (d 1.0) Decimal.zero))

(** Multiplication of two finance-realistic large decimals. The pre-
    fix implementation overflowed the int64 intermediate when either
    operand exceeded ~$920 in logical decimal value. *)
let test_mul_realistic_magnitudes () =
  dec_eq "100 * 100 = 10 000" (Decimal.of_int 10_000)
    (Decimal.mul (Decimal.of_int 100) (Decimal.of_int 100));
  dec_eq "30 000 * 100 = 3 000 000" (Decimal.of_int 3_000_000)
    (Decimal.mul (Decimal.of_int 30_000) (Decimal.of_int 100));
  dec_eq "1 000 * 1 000 = 1 000 000" (Decimal.of_int 1_000_000)
    (Decimal.mul (Decimal.of_int 1_000) (Decimal.of_int 1_000));
  (* Fractional: 0.85 × 100 000 = 85 000 (β-hedge sizing). *)
  dec_eq "0.85 * 100 000 = 85 000" (Decimal.of_int 85_000)
    (Decimal.mul (Decimal.of_string "0.85") (Decimal.of_int 100_000));
  (* Sign carries through. *)
  dec_eq "-1 000 * 1 000 = -1 000 000" (Decimal.of_int (-1_000_000))
    (Decimal.mul (Decimal.of_int (-1_000)) (Decimal.of_int 1_000));
  dec_eq "-1 000 * -1 000 = 1 000 000" (Decimal.of_int 1_000_000)
    (Decimal.mul (Decimal.of_int (-1_000)) (Decimal.of_int (-1_000)))

(** Division at finance-realistic magnitudes. The pre-fix
    implementation overflowed on the [(rem * unit_)] step whenever the
    divisor exceeded ~$920 in logical value. *)
let test_div_realistic_magnitudes () =
  (* The case that broke risk_policy_test. *)
  dec_eq "30 000 / 100 000 = 0.3" (Decimal.of_string "0.3")
    (Decimal.div (Decimal.of_int 30_000) (Decimal.of_int 100_000));
  dec_eq "1 / 1 000 = 0.001" (Decimal.of_string "0.001")
    (Decimal.div Decimal.one (Decimal.of_int 1_000));
  dec_eq "1 000 000 / 1 000 = 1 000" (Decimal.of_int 1_000)
    (Decimal.div (Decimal.of_int 1_000_000) (Decimal.of_int 1_000));
  (* Per-instrument cap derivation: 50 000 / 100 = 500. *)
  dec_eq "50 000 / 100 = 500" (Decimal.of_int 500)
    (Decimal.div (Decimal.of_int 50_000) (Decimal.of_int 100));
  (* Negative numerator preserves sign. *)
  dec_eq "-30 000 / 100 000 = -0.3" (Decimal.of_string "-0.3")
    (Decimal.div (Decimal.of_int (-30_000)) (Decimal.of_int 100_000))

(** [mul] then [div] should round-trip on values that don't lose
    precision. Stresses both operations together. *)
let test_mul_div_roundtrip () =
  let a = Decimal.of_int 1_000 in
  let b = Decimal.of_int 250 in
  let prod = Decimal.mul a b in
  dec_eq "(1 000 * 250) / 250 = 1 000" a (Decimal.div prod b)

(** Operations whose mathematically-exact result does not fit in int64
    must raise [Decimal_overflow], not silently wrap. *)
let test_mul_overflow_raises () =
  (* unit_ = 10^8, Int64.max ≈ 9.22 × 10^18. The decimal whose raw
     equals Int64.max represents ~9.22 × 10^10. Squaring 10^10 gives
     10^20, which exceeds Int64.max even after dividing by unit_. *)
  let huge =
    Decimal.of_string "10000000000"
    (* 10^10 *)
  in
  Alcotest.check_raises "10^10 * 10^10 overflows" Decimal.Decimal_overflow (fun () ->
      ignore (Decimal.mul huge huge))

let test_div_overflow_raises () =
  (* (a * unit_) / b where a is huge and b is tiny → result exceeds
     int64. *)
  let huge =
    Decimal.of_string "10000000000"
    (* 10^10 *)
  in
  let tiny =
    Decimal.of_string "0.00000001"
    (* 1 raw unit *)
  in
  Alcotest.check_raises "huge / tiny overflows" Decimal.Decimal_overflow (fun () ->
      ignore (Decimal.div huge tiny))

let qcheck_add_commutative =
  QCheck.Test.make ~name:"add commutative" ~count:500
    QCheck.(pair (float_range (-1e6) 1e6) (float_range (-1e6) 1e6))
    (fun (a, b) -> eq_dec (Decimal.add (d a) (d b)) (Decimal.add (d b) (d a)))

(** [mul] is commutative on values that don't overflow. Wider range
    than the existing add-commutativity property. *)
let qcheck_mul_commutative =
  QCheck.Test.make ~name:"mul commutative on bounded operands" ~count:500
    QCheck.(pair (int_range (-100_000) 100_000) (int_range (-100_000) 100_000))
    (fun (a, b) ->
      let da = Decimal.of_int a and db = Decimal.of_int b in
      Decimal.equal (Decimal.mul da db) (Decimal.mul db da))

(** [div] inverts [mul] when the divisor is non-zero. *)
let qcheck_div_inverts_mul =
  QCheck.Test.make ~name:"div inverts mul on bounded operands" ~count:500
    QCheck.(pair (int_range (-100_000) 100_000) (int_range 1 100_000))
    (fun (a, b) ->
      let da = Decimal.of_int a and db = Decimal.of_int b in
      let prod = Decimal.mul da db in
      Decimal.equal (Decimal.div prod db) da)

let tests =
  [
    ("zero", `Quick, test_zero);
    ("roundtrip float", `Quick, test_roundtrip);
    ("roundtrip string", `Quick, test_string_roundtrip);
    ("arithmetic", `Quick, test_arithmetic);
    ("div by zero", `Quick, test_div_by_zero);
    ("mul realistic magnitudes", `Quick, test_mul_realistic_magnitudes);
    ("div realistic magnitudes", `Quick, test_div_realistic_magnitudes);
    ("mul/div roundtrip", `Quick, test_mul_div_roundtrip);
    ("mul overflow raises", `Quick, test_mul_overflow_raises);
    ("div overflow raises", `Quick, test_div_overflow_raises);
    ("add commutative", `Quick, fun () -> QCheck.Test.check_exn qcheck_add_commutative);
    ("mul commutative", `Quick, fun () -> QCheck.Test.check_exn qcheck_mul_commutative);
    ("div inverts mul", `Quick, fun () -> QCheck.Test.check_exn qcheck_div_inverts_mul);
  ]

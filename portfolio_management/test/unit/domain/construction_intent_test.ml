(** Unit tests for the {!Construction_intent.t} value object and
    its associated VOs ({!Coupling}, {!Strength}, {!Source}). *)

module CI = Portfolio_management.Common.Construction_intent
module Source = Portfolio_management.Common.Source
module Strength = Portfolio_management.Common.Strength
module Coupling = Portfolio_management.Common.Coupling
module Direction = Portfolio_management.Common.Direction
module Book_id = Portfolio_management.Common.Book_id
module Pair = Portfolio_management.Common.Pair
module Alpha_source_id = Portfolio_management.Common.Alpha_source_id

let book () = Book_id.of_string "book-α"
let inst raw = Core.Instrument.of_qualified raw
let dec = Decimal.of_string

let alpha_source () = Source.Alpha_view (Alpha_source_id.of_string "momentum-1")

let pair_source ~a ~b = Source.Pair_mean_reversion (Pair.make ~a ~b)

(* --------------------------- Strength ----------------------------- *)

let test_strength_accepts_unit_range () =
  let _ = Strength.of_decimal Decimal.zero in
  let _ = Strength.of_decimal Decimal.one in
  let _ = Strength.of_decimal (dec "0.5") in
  Alcotest.(check pass) "constructed" () ()

let test_strength_rejects_negative () =
  Alcotest.check_raises "negative" (Invalid_argument "") (fun () ->
      try
        let _ = Strength.of_decimal (dec "-0.01") in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_strength_rejects_above_one () =
  Alcotest.check_raises "above 1" (Invalid_argument "") (fun () ->
      try
        let _ = Strength.of_decimal (dec "1.01") in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

(* --------------------------- Coupling ----------------------------- *)

let test_coupling_equal_when_same_inputs () =
  let a = Coupling.make 1700000000L in
  let b = Coupling.make 1700000000L in
  Alcotest.(check bool) "equal" true (Coupling.equal a b)

let test_coupling_differs_by_source () =
  let a = Coupling.make ~source:"pair_a" 1700000000L in
  let b = Coupling.make ~source:"pair_b" 1700000000L in
  Alcotest.(check bool) "differ" false (Coupling.equal a b)

(* --------------------------- Source ------------------------------- *)

let test_source_renders_alpha_view () =
  Alcotest.(check string)
    "rendered" "alpha_view:momentum-1"
    (Source.to_string (alpha_source ()))

let test_source_renders_pair () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  let prefix = "pair_mean_reversion:" in
  let rendered = Source.to_string (pair_source ~a ~b) in
  let n = String.length prefix in
  Alcotest.(check bool)
    "starts with pair_mean_reversion:" true
    (String.length rendered >= n && String.sub rendered 0 n = prefix)

(* --------------------- Construction_intent.scalar ----------------- *)

let test_scalar_constructed () =
  let i = inst "SBER@MISX" in
  let intent =
    CI.scalar ~book_id:(book ()) ~instrument:i ~direction:Direction.Up
      ~strength:(Strength.of_decimal (dec "0.7"))
      ~source:(alpha_source ()) ~observed_at:1700000000L
  in
  Alcotest.(check bool)
    "book_id roundtrip" true
    (Book_id.equal (CI.book_id intent) (book ()));
  Alcotest.(check int64) "observed_at roundtrip" 1700000000L (CI.observed_at intent)

(* --------------------- Construction_intent.coupled ---------------- *)

let coupling () = Coupling.make ~source:"pair_test" 1700000000L

let test_coupled_sorts_legs_by_instrument () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  let cpl = coupling () in
  let intent =
    CI.coupled ~book_id:(book ())
      ~legs:
        [
          { instrument = a; weight = dec "0.5" }; { instrument = b; weight = dec "-0.5" };
        ]
      ~coupling:cpl ~source:(pair_source ~a:b ~b:a) ~observed_at:1700000000L
  in
  match intent with
  | CI.Coupled c ->
      let sorted_instruments =
        List.map (fun (l : CI.leg) -> Core.Instrument.to_qualified l.instrument) c.legs
      in
      let expected = List.sort String.compare [ "SBER@MISX"; "GAZP@MISX" ] in
      Alcotest.(check (list string)) "sorted" expected sorted_instruments
  | CI.Scalar _ -> Alcotest.fail "expected Coupled"

let test_coupled_rejects_empty_legs () =
  Alcotest.check_raises "empty" (Invalid_argument "") (fun () ->
      try
        let _ =
          CI.coupled ~book_id:(book ()) ~legs:[] ~coupling:(coupling ())
            ~source:(alpha_source ()) ~observed_at:1700000000L
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_coupled_rejects_duplicate_instruments () =
  let a = inst "SBER@MISX" in
  Alcotest.check_raises "duplicate" (Invalid_argument "") (fun () ->
      try
        let _ =
          CI.coupled ~book_id:(book ())
            ~legs:
              [
                { instrument = a; weight = dec "0.3" };
                { instrument = a; weight = dec "-0.3" };
              ]
            ~coupling:(coupling ()) ~source:(alpha_source ()) ~observed_at:1700000000L
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_coupled_rejects_over_unit_leg () =
  let a = inst "SBER@MISX" in
  Alcotest.check_raises "leg above 1" (Invalid_argument "") (fun () ->
      try
        let _ =
          CI.coupled ~book_id:(book ())
            ~legs:[ { instrument = a; weight = dec "1.01" } ]
            ~coupling:(coupling ()) ~source:(alpha_source ()) ~observed_at:1700000000L
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_coupled_rejects_overweight_sum () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  Alcotest.check_raises "sum above 1" (Invalid_argument "") (fun () ->
      try
        let _ =
          CI.coupled ~book_id:(book ())
            ~legs:
              [
                { instrument = a; weight = dec "0.7" };
                { instrument = b; weight = dec "-0.6" };
              ]
            ~coupling:(coupling ()) ~source:(alpha_source ()) ~observed_at:1700000000L
        in
        ()
      with Invalid_argument _ -> raise (Invalid_argument ""))

let test_coupled_accepts_pair_at_boundary () =
  let a = inst "SBER@MISX" in
  let b = inst "GAZP@MISX" in
  let intent =
    CI.coupled ~book_id:(book ())
      ~legs:
        [
          { instrument = a; weight = dec "0.5" }; { instrument = b; weight = dec "-0.5" };
        ]
      ~coupling:(coupling ()) ~source:(alpha_source ()) ~observed_at:1700000000L
  in
  match intent with
  | CI.Coupled _ -> Alcotest.(check pass) "constructed" () ()
  | CI.Scalar _ -> Alcotest.fail "expected Coupled"

let tests =
  [
    Alcotest.test_case "Strength accepts [0,1]" `Quick test_strength_accepts_unit_range;
    Alcotest.test_case "Strength rejects negative" `Quick test_strength_rejects_negative;
    Alcotest.test_case "Strength rejects > 1" `Quick test_strength_rejects_above_one;
    Alcotest.test_case "Coupling equal when same inputs" `Quick
      test_coupling_equal_when_same_inputs;
    Alcotest.test_case "Coupling differs by source" `Quick test_coupling_differs_by_source;
    Alcotest.test_case "Source renders alpha_view" `Quick test_source_renders_alpha_view;
    Alcotest.test_case "Source renders pair" `Quick test_source_renders_pair;
    Alcotest.test_case "Scalar constructed and projections work" `Quick
      test_scalar_constructed;
    Alcotest.test_case "Coupled sorts legs by instrument" `Quick
      test_coupled_sorts_legs_by_instrument;
    Alcotest.test_case "Coupled rejects empty legs" `Quick test_coupled_rejects_empty_legs;
    Alcotest.test_case "Coupled rejects duplicate instruments" `Quick
      test_coupled_rejects_duplicate_instruments;
    Alcotest.test_case "Coupled rejects |weight| > 1 per leg" `Quick
      test_coupled_rejects_over_unit_leg;
    Alcotest.test_case "Coupled rejects Σ |weight| > 1" `Quick
      test_coupled_rejects_overweight_sum;
    Alcotest.test_case "Coupled accepts balanced pair at boundary" `Quick
      test_coupled_accepts_pair_at_boundary;
  ]

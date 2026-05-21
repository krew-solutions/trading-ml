(** Unit tests for the Iceberg strategy. *)

module Ot = Execution_management.Order_ticket
module Iceberg = Ot.Strategies.Iceberg
module Input = Ot.Strategies.Input
module Decision = Ot.Strategies.Decision
module Values = Ot.Values
module Placement = Ot.Placement

let qty s = Decimal.of_string s

let intent_total qty_s =
  let instrument =
    Core.Instrument.make
      ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty qty_s)

let placement_id_1 = Placement.Values.Placement_id.of_int 1

let full_fill quantity_s =
  Placement.Values.Fill_record.make ~quantity:(qty quantity_s)
    ~price:(Decimal.of_string "100") ~fee:Decimal.zero ~ts:0L

let test_init_emits_first_visible_chunk () =
  let intent = intent_total "100" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let _state, decision = Iceberg.init ~intent ~params ~now:0L in
  Alcotest.(check int) "one submit at init" 1 (List.length decision.submit);
  Alcotest.(check string)
    "first chunk = visible_qty" "10"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_total_smaller_than_visible_emits_total () =
  let intent = intent_total "5" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let _state, decision = Iceberg.init ~intent ~params ~now:0L in
  Alcotest.(check string)
    "chunk = total when remaining < visible" "5"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_full_chunk_fill_refills_next_chunk () =
  let intent = intent_total "100" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let _state', decision =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "10" })
      ~now:1L
  in
  Alcotest.(check int) "next chunk emitted" 1 (List.length decision.submit);
  Alcotest.(check string)
    "next chunk = visible_qty" "10"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_partial_fill_holds_next_chunk () =
  let intent = intent_total "100" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let _state', decision =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "4" })
      ~now:1L
  in
  Alcotest.(check int) "no refill on partial fill" 0 (List.length decision.submit)

let test_two_partial_fills_complete_chunk () =
  let intent = intent_total "100" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let state, _ =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "4" })
      ~now:1L
  in
  let _state', decision =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "6" })
      ~now:2L
  in
  Alcotest.(check int)
    "next chunk emitted after chunk complete" 1 (List.length decision.submit)

let test_full_intent_via_repeated_refills () =
  let intent = intent_total "30" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let state_ref = ref state in
  for _ = 1 to 3 do
    let state', _ =
      Iceberg.on_event !state_ref
        (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "10" })
        ~now:0L
    in
    state_ref := state'
  done;
  Alcotest.(check bool)
    "complete after Σ fills = total" true
    (Iceberg.is_complete !state_ref)

let test_last_chunk_smaller_than_visible () =
  let intent = intent_total "25" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let state, _ =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "10" })
      ~now:1L
  in
  let _state', decision =
    Iceberg.on_event state
      (Input.Placement_filled { placement_id = placement_id_1; fill = full_fill "10" })
      ~now:2L
  in
  Alcotest.(check string)
    "last chunk = remaining (5)" "5"
    (Decimal.to_string (List.hd decision.submit).quantity)

let test_rejection_terminates_failed () =
  let intent = intent_total "100" in
  let params = Values.Iceberg_params.make ~visible_qty:(qty "10") in
  let state, _ = Iceberg.init ~intent ~params ~now:0L in
  let _state', decision =
    Iceberg.on_event state
      (Input.Placement_rejected { placement_id = placement_id_1; reason = "venue down" })
      ~now:1L
  in
  match decision.terminal with
  | Decision.Failed _ -> ()
  | _ -> Alcotest.fail "rejection should terminate Failed"

let tests =
  [
    Alcotest.test_case "init emits first visible chunk" `Quick
      test_init_emits_first_visible_chunk;
    Alcotest.test_case "total < visible: emit total" `Quick
      test_total_smaller_than_visible_emits_total;
    Alcotest.test_case "full chunk fill triggers next chunk" `Quick
      test_full_chunk_fill_refills_next_chunk;
    Alcotest.test_case "partial fill holds next chunk" `Quick
      test_partial_fill_holds_next_chunk;
    Alcotest.test_case "two partial fills complete a chunk" `Quick
      test_two_partial_fills_complete_chunk;
    Alcotest.test_case "full intent via repeated refills" `Quick
      test_full_intent_via_repeated_refills;
    Alcotest.test_case "last chunk smaller than visible" `Quick
      test_last_chunk_smaller_than_visible;
    Alcotest.test_case "rejection terminates Failed" `Quick
      test_rejection_terminates_failed;
  ]

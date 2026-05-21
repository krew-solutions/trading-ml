(** Round-trip + of_domain projection coverage for
    {!Order_ticket_view_model.t} and the lifecycle/strategy
    branches it folds across. *)

module Ot = Execution_management.Order_ticket
module Values = Ot.Values
module Vm = Execution_management_view_models.Order_ticket_view_model

let qty s = Decimal.of_string s

let intent_buy_100 () =
  let instrument =
    Core.Instrument.make
      ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty "100")

let ticket_id_42 = Values.Ticket_id.of_int 42
let reservation_id_42 = Values.Reservation_id.of_int 42

let test_immediate_open_projects_working_lifecycle () =
  let t, _ =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~intent:(intent_buy_100 ()) ~directive:Values.Execution_directive.Immediate
      ~now:1_700_000_000L
  in
  let vm = Vm.of_domain t in
  Alcotest.(check int) "ticket_id propagated" 42 vm.ticket_id;
  Alcotest.(check string) "book_id propagated" "alpha" vm.book_id;
  Alcotest.(check string) "side propagated" "BUY" vm.side;
  Alcotest.(check string) "directive.kind = IMMEDIATE" "IMMEDIATE" vm.directive.kind;
  Alcotest.(check (option string)) "no params for IMMEDIATE" None vm.directive.params;
  Alcotest.(check string) "lifecycle = WORKING" "WORKING" vm.lifecycle;
  Alcotest.(check (option string))
    "no lifecycle_reason in WORKING" None vm.lifecycle_reason;
  Alcotest.(check string) "strategy.kind = IMMEDIATE" "IMMEDIATE" vm.strategy.kind;
  Alcotest.(check int) "one placement materialised at open" 1 (List.length vm.placements)

let test_twap_directive_carries_params_blob () =
  let params = Values.Twap_params.make ~n_slices:4 ~window_seconds:60 ~start_at:1_000L in
  let t, _ =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~intent:(intent_buy_100 ()) ~directive:(Values.Execution_directive.Twap params)
      ~now:0L
  in
  let vm = Vm.of_domain t in
  Alcotest.(check string) "directive.kind = TWAP" "TWAP" vm.directive.kind;
  Alcotest.(check bool) "params present" true (Option.is_some vm.directive.params);
  let params_blob = Option.get vm.directive.params in
  (* The blob is a JSON object — parse it back to assert content. *)
  let parsed = Yojson.Safe.from_string params_blob in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "n_slices in params blob" 4 (parsed |> member "n_slices" |> to_int);
  Alcotest.(check int)
    "window_seconds in params blob" 60
    (parsed |> member "window_seconds" |> to_int)

let test_round_trip_json () =
  let t, _ =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~intent:(intent_buy_100 ()) ~directive:Values.Execution_directive.Immediate
      ~now:1_700_000_000L
  in
  let vm = Vm.of_domain t in
  let s = Vm.string_of_t vm in
  let vm' = Vm.t_of_string s in
  Alcotest.(check int) "ticket_id survives round-trip" vm.ticket_id vm'.ticket_id;
  Alcotest.(check string) "lifecycle survives" vm.lifecycle vm'.lifecycle;
  Alcotest.(check int)
    "placements count survives" (List.length vm.placements) (List.length vm'.placements)

let tests =
  [
    Alcotest.test_case "Immediate open projects WORKING lifecycle" `Quick
      test_immediate_open_projects_working_lifecycle;
    Alcotest.test_case "TWAP directive carries params blob" `Quick
      test_twap_directive_carries_params_blob;
    Alcotest.test_case "Order_ticket_view_model JSON round-trip" `Quick
      test_round_trip_json;
  ]

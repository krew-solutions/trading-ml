(** Wire-projection coverage for the four ticket-lifecycle IEs. *)

module Ot = Execution_management.Order_ticket
module Values = Ot.Values
module Events = Ot.Events
module Ie = Execution_management_integration_events

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

let test_opened_carries_correlation_intent_directive () =
  let intent = intent_buy_100 () in
  let domain_ev =
    Events.Ticket_opened.make ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~intent ~directive:Values.Execution_directive.Immediate ~occurred_at:1_700_000_000L
  in
  let ie =
    Ie.Order_ticket_opened_integration_event.of_domain ~correlation_id:"saga-A" domain_ev
  in
  Alcotest.(check string) "correlation_id threaded" "saga-A" ie.correlation_id;
  Alcotest.(check int) "ticket_id propagated" 42 ie.ticket_id;
  Alcotest.(check string) "book_id propagated" "alpha" ie.book_id;
  Alcotest.(check string) "side propagated" "BUY" ie.side;
  Alcotest.(check string) "directive.kind = IMMEDIATE" "IMMEDIATE" ie.directive.kind

let test_completed_carries_progress () =
  let progress = Values.Progress.empty ~total_quantity:(qty "100") in
  let progress =
    Values.Progress.apply_fill progress
      ~fill:
        (Ot.Placement.Values.Fill_record.make ~quantity:(qty "100") ~price:(qty "250")
           ~fee:(qty "0.5") ~ts:1_700_000_000L)
  in
  let domain_ev =
    Events.Ticket_completed.make ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~progress ~occurred_at:1_700_000_001L
  in
  let ie =
    Ie.Order_ticket_completed_integration_event.of_domain ~correlation_id:"saga-A"
      domain_ev
  in
  Alcotest.(check string) "total_quantity = 100" "100" ie.progress.total_quantity;
  Alcotest.(check string) "cumulative_filled = 100" "100" ie.progress.cumulative_filled;
  Alcotest.(check string) "remaining = 0" "0" ie.progress.remaining_quantity

let test_cancelled_carries_reason_string () =
  let progress = Values.Progress.empty ~total_quantity:(qty "100") in
  let domain_ev =
    Events.Ticket_cancelled.make ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~reason:Values.Cancel_reason.Operator ~progress ~occurred_at:1_700_000_002L
  in
  let ie =
    Ie.Order_ticket_cancelled_integration_event.of_domain ~correlation_id:"saga-A"
      domain_ev
  in
  Alcotest.(check string) "reason serialised to wire form" "operator" ie.reason

let test_failed_carries_free_form_reason () =
  let progress = Values.Progress.empty ~total_quantity:(qty "100") in
  let domain_ev =
    Events.Ticket_failed.make ~ticket_id:ticket_id_42 ~reservation_id:reservation_id_42
      ~reason:"venue rejected: instrument suspended" ~progress ~occurred_at:1_700_000_003L
  in
  let ie =
    Ie.Order_ticket_failed_integration_event.of_domain ~correlation_id:"saga-A" domain_ev
  in
  Alcotest.(check string)
    "reason propagated verbatim" "venue rejected: instrument suspended" ie.reason

let tests =
  [
    Alcotest.test_case "Opened: correlation + intent + directive" `Quick
      test_opened_carries_correlation_intent_directive;
    Alcotest.test_case "Completed: full progress projection" `Quick
      test_completed_carries_progress;
    Alcotest.test_case "Cancelled: reason serialised" `Quick
      test_cancelled_carries_reason_string;
    Alcotest.test_case "Failed: free-form reason" `Quick
      test_failed_carries_free_form_reason;
  ]

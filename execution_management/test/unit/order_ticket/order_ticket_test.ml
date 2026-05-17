(** Unit tests for the OrderTicket aggregate root. Pure-domain
    coverage of: open via various directives, placement lifecycle,
    cumulative fill aggregation, operator cancel, terminal
    absorbtion of late events. *)

module Ot = Execution_management.Order_ticket
module Values = Ot.Values
module Placement = Ot.Placement
module Strategies = Ot.Strategies

let qty s = Decimal.of_string s

let intent_buy_100 () =
  let instrument =
    Core.Instrument.make ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ~board:None ~isin:None
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty "100")

let ticket_id_42 = Values.Ticket_id.of_int 42

let full_fill quantity_s =
  Placement.Values.Fill_record.make ~quantity:(qty quantity_s)
    ~price:(Decimal.of_string "250") ~fee:(Decimal.of_string "0.5")
    ~ts:1_700_000_000L

let count_kind events filter =
  List.length (List.filter filter events)

(* ---------- open_ticket ---------- *)

let test_open_immediate_emits_opened_plus_one_dispatched () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:1_700_000_000L
  in
  Alcotest.(check int)
    "1 opened event" 1
    (count_kind events (function Ot.Ev_ticket_opened _ -> true | _ -> false));
  Alcotest.(check int)
    "1 placement dispatched" 1
    (count_kind events (function
      | Ot.Ev_placement_dispatched _ -> true
      | _ -> false));
  Alcotest.(check bool) "lifecycle is Working" true
    (match Ot.lifecycle t with Working _ -> true | _ -> false);
  Alcotest.(check int) "1 placement on ticket" 1
    (List.length (Ot.placements t))

let test_open_twap_emits_no_immediate_placement () =
  let params =
    Values.Twap_params.make ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
  in
  let _t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:(Values.Execution_directive.Twap params) ~now:0L
  in
  Alcotest.(check int) "no placements at TWAP open" 0
    (count_kind events (function
      | Ot.Ev_placement_dispatched _ -> true
      | _ -> false))

(* ---------- happy path Immediate ---------- *)

let test_immediate_full_fill_completes_ticket () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:1_700_000_000L
  in
  let pid =
    match
      List.find_map
        (function
          | Ot.Ev_placement_dispatched
              (e : Ot.Events.Placement_dispatched.t) -> Some e.placement_id
          | _ -> None)
        events
    with
    | Some p -> p
    | None -> Alcotest.fail "no placement_id minted at open"
  in
  let t, _ = Ot.on_placement_acknowledged t ~placement_id:pid ~now:1_700_000_001L in
  let t, events =
    Ot.on_placement_fill t ~placement_id:pid ~fill:(full_fill "100")
      ~now:1_700_000_002L
  in
  Alcotest.(check int)
    "1 Ticket_completed emitted" 1
    (count_kind events (function
      | Ot.Ev_ticket_completed _ -> true
      | _ -> false));
  Alcotest.(check bool) "lifecycle is Filled" true
    (match Ot.lifecycle t with Filled -> true | _ -> false);
  Alcotest.(check string)
    "Σ filled = total" "100"
    (Decimal.to_string (Values.Progress.remaining_quantity (Ot.progress t))
    |> fun s -> if s = "0" then "100" else "");
  Alcotest.(check bool) "is_terminal true" true (Ot.is_terminal t)

(* ---------- partial fills ---------- *)

let test_partial_then_full_fill_completes_only_at_end () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:0L
  in
  let pid =
    match List.find_map (function Ot.Ev_placement_dispatched e -> Some e.placement_id | _ -> None) events with
    | Some p -> p
    | None -> Alcotest.fail "no placement"
  in
  let t, evs1 = Ot.on_placement_fill t ~placement_id:pid ~fill:(full_fill "40") ~now:1L in
  Alcotest.(check int) "no completed on partial" 0
    (count_kind evs1 (function Ot.Ev_ticket_completed _ -> true | _ -> false));
  let t, evs2 = Ot.on_placement_fill t ~placement_id:pid ~fill:(full_fill "60") ~now:2L in
  Alcotest.(check int) "completed on second (final) fill" 1
    (count_kind evs2 (function Ot.Ev_ticket_completed _ -> true | _ -> false));
  Alcotest.(check bool) "lifecycle Filled" true
    (match Ot.lifecycle t with Filled -> true | _ -> false)

(* ---------- rejection ---------- *)

let test_immediate_rejection_terminates_failed () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:0L
  in
  let pid =
    match List.find_map (function Ot.Ev_placement_dispatched e -> Some e.placement_id | _ -> None) events with
    | Some p -> p
    | None -> Alcotest.fail "no placement"
  in
  let t, evs =
    Ot.on_placement_rejection t ~placement_id:pid ~reason:"venue down" ~now:1L
  in
  Alcotest.(check int) "Ticket_failed emitted" 1
    (count_kind evs (function Ot.Ev_ticket_failed _ -> true | _ -> false));
  Alcotest.(check bool) "lifecycle Failed" true
    (match Ot.lifecycle t with Failed _ -> true | _ -> false)

(* ---------- TWAP integration ---------- *)

let test_twap_tick_emits_slice () =
  let params =
    Values.Twap_params.make ~n_slices:4 ~window_seconds:60 ~start_at:1_000L
  in
  let t, _ =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:(Values.Execution_directive.Twap params) ~now:0L
  in
  let _t, events = Ot.on_clock_tick t ~now:1_000L in
  Alcotest.(check int) "1 placement dispatched on first tick" 1
    (count_kind events (function Ot.Ev_placement_dispatched _ -> true | _ -> false))

(* ---------- cancel ---------- *)

let test_cancel_emits_cancelling_started () =
  let t, _ =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:0L
  in
  let _t, events = Ot.cancel t ~reason:Values.Cancel_reason.Operator ~now:1L in
  Alcotest.(check int) "cancelling_started emitted" 1
    (count_kind events (function
      | Ot.Ev_ticket_cancelling_started _ -> true
      | _ -> false))

let test_cancel_then_placement_cancelled_completes_to_cancelled () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:0L
  in
  let pid =
    match List.find_map (function Ot.Ev_placement_dispatched e -> Some e.placement_id | _ -> None) events with
    | Some p -> p
    | None -> Alcotest.fail "no placement"
  in
  let t, _ = Ot.cancel t ~reason:Values.Cancel_reason.Operator ~now:1L in
  let t, evs = Ot.on_placement_cancelled t ~placement_id:pid ~now:2L in
  Alcotest.(check int) "Ticket_cancelled emitted when last outstanding cancels" 1
    (count_kind evs (function Ot.Ev_ticket_cancelled _ -> true | _ -> false));
  Alcotest.(check bool) "lifecycle Cancelled" true
    (match Ot.lifecycle t with Cancelled _ -> true | _ -> false)

(* ---------- late event absorbtion ---------- *)

let test_late_event_in_filled_is_noop () =
  let t, events =
    Ot.open_ticket ~ticket_id:ticket_id_42 ~intent:(intent_buy_100 ())
      ~directive:Values.Execution_directive.Immediate ~now:0L
  in
  let pid =
    match List.find_map (function Ot.Ev_placement_dispatched e -> Some e.placement_id | _ -> None) events with
    | Some p -> p
    | None -> Alcotest.fail "no placement"
  in
  let t, _ = Ot.on_placement_fill t ~placement_id:pid ~fill:(full_fill "100") ~now:1L in
  (* now in Filled — any further event should be absorbed *)
  let _t', evs =
    Ot.on_placement_rejection t ~placement_id:pid ~reason:"late ack" ~now:2L
  in
  Alcotest.(check int) "no events in terminal" 0 (List.length evs)

let tests =
  [
    Alcotest.test_case "open Immediate emits Opened + Dispatched" `Quick
      test_open_immediate_emits_opened_plus_one_dispatched;
    Alcotest.test_case "open TWAP emits no immediate placement" `Quick
      test_open_twap_emits_no_immediate_placement;
    Alcotest.test_case "Immediate full fill → Ticket_completed" `Quick
      test_immediate_full_fill_completes_ticket;
    Alcotest.test_case "Partial then full fill: completed only at end" `Quick
      test_partial_then_full_fill_completes_only_at_end;
    Alcotest.test_case "Immediate rejection → Ticket_failed" `Quick
      test_immediate_rejection_terminates_failed;
    Alcotest.test_case "TWAP tick emits scheduled slice" `Quick
      test_twap_tick_emits_slice;
    Alcotest.test_case "cancel emits Ticket_cancelling_started" `Quick
      test_cancel_emits_cancelling_started;
    Alcotest.test_case
      "cancel then placement_cancelled → Ticket_cancelled" `Quick
      test_cancel_then_placement_cancelled_completes_to_cancelled;
    Alcotest.test_case "late event in Filled is noop" `Quick
      test_late_event_in_filled_is_noop;
  ]

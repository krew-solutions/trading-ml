(** Unit tests for {!Paper_broker.Order} — entity lifecycle. *)

module Order = Paper_broker.Order
module Order_kind = Order.Values.Order_kind
module Order_status = Order.Values.Order_status
module Placement_id = Order.Values.Placement_id
module Time_in_force = Order.Values.Time_in_force
open Core

let dec = Decimal.of_string
let pid = Placement_id.of_int

let inst =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

let new_buy_market ?(quantity = "10") () =
  let o, _ev =
    Order.make ~id:"po-1" ~placement_id:(pid 1) ~instrument:inst ~side:Side.Buy
      ~quantity:(dec quantity) ~kind:Order_kind.market ~tif:Time_in_force.GTC
      ~created_ts:1_700_000_000L ~placed_after_ts:1_700_000_000L
  in
  o

let test_make_returns_new_status () =
  let o = new_buy_market () in
  Alcotest.(check string) "status" "New" (Order_status.to_string o.status);
  Alcotest.(check bool)
    "remaining = quantity" true
    (Decimal.equal (Order.remaining o) o.quantity);
  Alcotest.(check bool) "filled = 0" true (Decimal.is_zero o.filled)

let test_make_rejects_non_positive_quantity () =
  match
    Order.make ~id:"x" ~placement_id:(pid 1) ~instrument:inst ~side:Side.Buy
      ~quantity:Decimal.zero ~kind:Order_kind.market ~tif:Time_in_force.GTC ~created_ts:0L
      ~placed_after_ts:0L
  with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument for quantity=0"

let test_placement_id_rejects_zero () =
  match Placement_id.of_int 0 with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument for placement_id=0"

let test_placement_id_rejects_negative () =
  match Placement_id.of_int (-1) with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument for placement_id=-1"

let test_partial_fill_transitions_to_partially_filled () =
  let o = new_buy_market ~quantity:"10" () in
  match
    Order.commit_fill o ~trade_id:"e1" ~fill_quantity:(dec "3") ~fill_price:(dec "100")
      ~fee:Decimal.zero ~fill_ts:1_700_000_001L
  with
  | Error _ -> Alcotest.fail "expected Ok"
  | Ok (o', ev) ->
      Alcotest.(check string)
        "status" "Partially_filled"
        (Order_status.to_string o'.status);
      Alcotest.(check bool) "filled = 3" true (Decimal.equal o'.filled (dec "3"));
      Alcotest.(check bool)
        "remaining = 7" true
        (Decimal.equal (Order.remaining o') (dec "7"));
      Alcotest.(check string) "event trade_id" "e1" ev.trade_id;
      Alcotest.(check bool)
        "event quantity = 3" true
        (Decimal.equal ev.quantity (dec "3"))

let test_full_fill_transitions_to_filled () =
  let o = new_buy_market ~quantity:"10" () in
  match
    Order.commit_fill o ~trade_id:"e1" ~fill_quantity:(dec "10") ~fill_price:(dec "100")
      ~fee:Decimal.zero ~fill_ts:1_700_000_001L
  with
  | Error _ -> Alcotest.fail "expected Ok"
  | Ok (o', _ev) ->
      Alcotest.(check string) "status" "Filled" (Order_status.to_string o'.status);
      Alcotest.(check bool) "filled = quantity" true (Decimal.equal o'.filled o'.quantity);
      Alcotest.(check bool) "terminal" true (Order.is_terminal o')

let test_fill_after_terminal_rejected () =
  let o = new_buy_market ~quantity:"10" () in
  let o' =
    match
      Order.commit_fill o ~trade_id:"e1" ~fill_quantity:(dec "10") ~fill_price:(dec "100")
        ~fee:Decimal.zero ~fill_ts:1_700_000_001L
    with
    | Ok (o', _) -> o'
    | Error _ -> Alcotest.fail "first fill should succeed"
  in
  match
    Order.commit_fill o' ~trade_id:"e2" ~fill_quantity:(dec "1") ~fill_price:(dec "100")
      ~fee:Decimal.zero ~fill_ts:1_700_000_002L
  with
  | Error (Order.Order_already_terminal Filled) -> ()
  | _ -> Alcotest.fail "expected Order_already_terminal Filled"

let test_overfill_rejected () =
  let o = new_buy_market ~quantity:"10" () in
  match
    Order.commit_fill o ~trade_id:"e1" ~fill_quantity:(dec "11") ~fill_price:(dec "100")
      ~fee:Decimal.zero ~fill_ts:1_700_000_001L
  with
  | Error (Order.Overfill { remaining; attempted }) ->
      Alcotest.(check string) "remaining" "10" (Decimal.to_string remaining);
      Alcotest.(check string) "attempted" "11" (Decimal.to_string attempted)
  | _ -> Alcotest.fail "expected Overfill"

let test_cancel_from_new_succeeds () =
  let o = new_buy_market () in
  match Order.cancel o ~cancelled_ts:1_700_000_001L with
  | Ok (o', ev) ->
      Alcotest.(check string) "status" "Cancelled" (Order_status.to_string o'.status);
      Alcotest.(check string) "event id" "po-1" ev.id;
      Alcotest.(check bool) "terminal" true (Order.is_terminal o')
  | Error _ -> Alcotest.fail "expected Ok"

let test_cancel_after_filled_rejected () =
  let o = new_buy_market ~quantity:"5" () in
  let o' =
    match
      Order.commit_fill o ~trade_id:"e1" ~fill_quantity:(dec "5") ~fill_price:(dec "100")
        ~fee:Decimal.zero ~fill_ts:1_700_000_001L
    with
    | Ok (o', _) -> o'
    | Error _ -> Alcotest.fail "first fill should succeed"
  in
  match Order.cancel o' ~cancelled_ts:1_700_000_002L with
  | Error (Order.Order_already_terminal Filled) -> ()
  | _ -> Alcotest.fail "expected Order_already_terminal Filled"

let tests =
  [
    ("make returns New status", `Quick, test_make_returns_new_status);
    ("make rejects non-positive quantity", `Quick, test_make_rejects_non_positive_quantity);
    ( "partial fill -> Partially_filled",
      `Quick,
      test_partial_fill_transitions_to_partially_filled );
    ("full fill -> Filled", `Quick, test_full_fill_transitions_to_filled);
    ("fill after terminal rejected", `Quick, test_fill_after_terminal_rejected);
    ("overfill rejected", `Quick, test_overfill_rejected);
    ("cancel from New succeeds", `Quick, test_cancel_from_new_succeeds);
    ("cancel after Filled rejected", `Quick, test_cancel_after_filled_rejected);
    ("Placement_id rejects 0", `Quick, test_placement_id_rejects_zero);
    ("Placement_id rejects -1", `Quick, test_placement_id_rejects_negative);
  ]

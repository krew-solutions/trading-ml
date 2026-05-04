open Core
module Pm = Portfolio_management
module Alpha_view = Pm.Alpha_view
module Common = Pm.Common
module Direction_changed = Alpha_view.Events.Direction_changed

let alpha_source = Common.Alpha_source_id.of_string "strategy:bollinger_revert/v1"
let inst = Instrument.of_qualified "SBER@MISX"
let dec = Decimal.of_int

let empty () = Alpha_view.empty ~alpha_source_id:alpha_source ~instrument:inst

let test_first_define_from_flat_emits_event () =
  let t = empty () in
  let t', ev =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:0.7 ~price:(dec 100)
      ~occurred_at:10L
  in
  Alcotest.(check bool)
    "direction set to Up" true
    (Common.Direction.equal t'.direction Common.Direction.Up);
  Alcotest.(check (float 1e-9)) "strength stored" 0.7 t'.strength;
  Alcotest.(check bool) "last_price set" true (Decimal.equal t'.last_price (dec 100));
  Alcotest.(check int64) "last_observed_at set" 10L t'.last_observed_at;
  match ev with
  | None -> Alcotest.fail "expected Direction_changed event"
  | Some (e : Direction_changed.t) ->
      Alcotest.(check bool)
        "previous_direction was Flat" true
        (Common.Direction.equal e.previous_direction Common.Direction.Flat);
      Alcotest.(check bool)
        "new_direction is Up" true
        (Common.Direction.equal e.new_direction Common.Direction.Up);
      Alcotest.(check int64) "occurred_at carried" 10L e.occurred_at

let test_redefine_same_direction_emits_no_event () =
  let t = empty () in
  let t1, _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:0.5 ~price:(dec 100)
      ~occurred_at:10L
  in
  let t2, ev =
    Alpha_view.define t1 ~direction:Common.Direction.Up ~strength:0.9 ~price:(dec 110)
      ~occurred_at:20L
  in
  Alcotest.(check bool) "no event" true (ev = None);
  Alcotest.(check (float 1e-9)) "strength refreshed" 0.9 t2.strength;
  Alcotest.(check bool)
    "last_price refreshed" true
    (Decimal.equal t2.last_price (dec 110));
  Alcotest.(check int64) "last_observed_at advanced" 20L t2.last_observed_at

let test_direction_flip_emits_event () =
  let t = empty () in
  let t1, _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:0.6 ~price:(dec 100)
      ~occurred_at:10L
  in
  let t2, ev =
    Alpha_view.define t1 ~direction:Common.Direction.Down ~strength:0.8 ~price:(dec 95)
      ~occurred_at:20L
  in
  Alcotest.(check bool)
    "direction flipped to Down" true
    (Common.Direction.equal t2.direction Common.Direction.Down);
  match ev with
  | None -> Alcotest.fail "expected Direction_changed event"
  | Some e ->
      Alcotest.(check bool)
        "previous Up" true
        (Common.Direction.equal e.previous_direction Common.Direction.Up);
      Alcotest.(check bool)
        "new Down" true
        (Common.Direction.equal e.new_direction Common.Direction.Down)

let test_late_occurred_at_is_no_op () =
  let t = empty () in
  let t1, _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:0.5 ~price:(dec 100)
      ~occurred_at:20L
  in
  let t2, ev =
    Alpha_view.define t1 ~direction:Common.Direction.Down ~strength:0.9 ~price:(dec 50)
      ~occurred_at:10L
  in
  Alcotest.(check bool) "no event" true (ev = None);
  Alcotest.(check bool)
    "direction unchanged" true
    (Common.Direction.equal t2.direction Common.Direction.Up);
  Alcotest.(check int64) "last_observed_at unchanged" 20L t2.last_observed_at

let test_strength_clamped_above_one () =
  let t = empty () in
  let t', _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:1.7 ~price:(dec 100)
      ~occurred_at:10L
  in
  Alcotest.(check (float 1e-9)) "strength clamped to 1.0" 1.0 t'.strength

let test_strength_clamped_below_zero () =
  let t = empty () in
  let t', _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:(-0.4) ~price:(dec 100)
      ~occurred_at:10L
  in
  Alcotest.(check (float 1e-9)) "strength clamped to 0.0" 0.0 t'.strength

let test_equal_occurred_at_is_no_op () =
  let t = empty () in
  let t1, _ =
    Alpha_view.define t ~direction:Common.Direction.Up ~strength:0.5 ~price:(dec 100)
      ~occurred_at:10L
  in
  let t2, ev =
    Alpha_view.define t1 ~direction:Common.Direction.Down ~strength:0.9 ~price:(dec 50)
      ~occurred_at:10L
  in
  Alcotest.(check bool) "no event on equal ts" true (ev = None);
  Alcotest.(check bool)
    "state unchanged" true
    (Common.Direction.equal t2.direction Common.Direction.Up)

let tests =
  [
    ("first define from Flat emits event", `Quick, test_first_define_from_flat_emits_event);
    ( "redefine with same direction emits no event",
      `Quick,
      test_redefine_same_direction_emits_no_event );
    ("direction flip emits event", `Quick, test_direction_flip_emits_event);
    ("late occurred_at is no-op", `Quick, test_late_occurred_at_is_no_op);
    ("equal occurred_at is no-op", `Quick, test_equal_occurred_at_is_no_op);
    ("strength clamped above 1.0", `Quick, test_strength_clamped_above_one);
    ("strength clamped below 0.0", `Quick, test_strength_clamped_below_zero);
  ]

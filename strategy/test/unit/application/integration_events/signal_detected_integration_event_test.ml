(** Locks in the projection of {!Common.Signal.action} onto the
    integration event's [direction] string. The previous mapping
    silently routed [Exit_long] / [Exit_short] — bracket-exit events,
    which mean «alpha withdrawn, outcome = SL/TP/timeout» — into
    ["DOWN"] / ["UP"], inverting their semantics for any downstream
    PM alpha-policy. The fix is to map them to ["FLAT"] (alpha-expiry)
    while preserving the outcome label in [reason]. *)

open Core
module Sd_ie = Strategy_integration_events.Signal_detected_integration_event

let inst = Instrument.of_qualified "SBER@MISX"
let price = Decimal.of_int 100

let signal_with ~action ~reason : Signal.t =
  {
    ts = 1700000000L;
    instrument = inst;
    action;
    strength = 0.5;
    stop_loss = None;
    take_profit = None;
    reason;
  }

let project signal = Sd_ie.of_domain ~strategy_id:"test" ~price signal

let case ~name ~action ~reason ~expected_direction () =
  let ie = project (signal_with ~action ~reason) in
  Alcotest.(check string) (name ^ ": direction") expected_direction ie.direction;
  Alcotest.(check string) (name ^ ": reason preserved") reason ie.reason

let test_enter_long_is_up =
  case ~name:"Enter_long" ~action:Signal.Enter_long ~reason:"trend up"
    ~expected_direction:"UP"

let test_enter_short_is_down =
  case ~name:"Enter_short" ~action:Signal.Enter_short ~reason:"trend down"
    ~expected_direction:"DOWN"

let test_exit_long_is_flat =
  case ~name:"Exit_long" ~action:Signal.Exit_long ~reason:"SL hit"
    ~expected_direction:"FLAT"

let test_exit_short_is_flat =
  case ~name:"Exit_short" ~action:Signal.Exit_short ~reason:"TP hit"
    ~expected_direction:"FLAT"

let test_hold_is_flat =
  case ~name:"Hold" ~action:Signal.Hold ~reason:"" ~expected_direction:"FLAT"

let tests =
  [
    ("Enter_long projects to UP", `Quick, test_enter_long_is_up);
    ("Enter_short projects to DOWN", `Quick, test_enter_short_is_down);
    ("Exit_long projects to FLAT (alpha-expiry)", `Quick, test_exit_long_is_flat);
    ("Exit_short projects to FLAT (alpha-expiry)", `Quick, test_exit_short_is_flat);
    ("Hold projects to FLAT", `Quick, test_hold_is_flat);
  ]

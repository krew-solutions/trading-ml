(** Tests for [Composite] strategy — voting policies, exit priority,
    strength averaging. Uses fake "always enter_long" and "always
    exit_long" strategy stubs to control signals deterministically. *)

open Core

open Strategy_helpers

(** Stub strategy that always emits a fixed action with given strength. *)
module Stub = struct
  type state = Signal.action * float
  type params = state
  let name = "Stub"
  let default_params = (Signal.Hold, 0.0)
  let init p = p
  let on_candle (action, strength) instrument (c : Candle.t) =
    (action, strength),
    { Signal.ts = c.ts; instrument; action; strength;
      stop_loss = None; take_profit = None; reason = "stub" }
end

let mk_stub action strength =
  Strategies.Strategy.make (module Stub) (action, strength)

let run_composite ~policy children prices =
  let strat = Strategies.Strategy.make (module Strategies.Composite)
    Strategies.Composite.{ policy; children } in
  actions_from_prices strat prices

(** --- Unanimous --- *)

let test_unanimous_all_agree () =
  let children = [
    mk_stub Signal.Enter_long 0.8;
    mk_stub Signal.Enter_long 0.6;
  ] in
  let acts = run_composite ~policy:Unanimous children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "enter_long when all agree" true
    (contains Signal.Enter_long acts)

let test_unanimous_disagree () =
  let children = [
    mk_stub Signal.Enter_long 0.8;
    mk_stub Signal.Hold 0.0;
  ] in
  let acts = run_composite ~policy:Unanimous children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "hold when not unanimous" true
    (not (contains Signal.Enter_long acts))

(** --- Majority --- *)

let test_majority_passes () =
  let children = [
    mk_stub Signal.Enter_long 0.8;
    mk_stub Signal.Enter_long 0.6;
    mk_stub Signal.Hold 0.0;
  ] in
  let acts = run_composite ~policy:Majority children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "enter_long with 2/3 majority" true
    (contains Signal.Enter_long acts)

let test_majority_fails () =
  let children = [
    mk_stub Signal.Enter_long 0.8;
    mk_stub Signal.Hold 0.0;
    mk_stub Signal.Hold 0.0;
  ] in
  let acts = run_composite ~policy:Majority children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "hold with only 1/3" true
    (not (contains Signal.Enter_long acts))

(** --- Any --- *)

let test_any_single_voter () =
  let children = [
    mk_stub Signal.Enter_long 0.5;
    mk_stub Signal.Hold 0.0;
    mk_stub Signal.Hold 0.0;
  ] in
  let acts = run_composite ~policy:Any children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "enter_long with any=1" true
    (contains Signal.Enter_long acts)

(** --- Exit > Enter priority --- *)

let test_exit_beats_enter () =
  let children = [
    mk_stub Signal.Enter_long 0.8;
    mk_stub Signal.Exit_long 0.6;
  ] in
  let acts = run_composite ~policy:Any children
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "exit_long wins over enter_long" true
    (contains Signal.Exit_long acts);
  Alcotest.(check bool) "no enter_long" true
    (not (contains Signal.Enter_long acts))

(** --- Empty children --- *)

let test_empty_children_hold () =
  let acts = run_composite ~policy:Any []
    (List.init 5 (fun _ -> 100.)) in
  Alcotest.(check bool) "all hold with no children" true
    (not (contains Signal.Enter_long acts))

(** --- Registry lookup --- *)

let test_registry_has_composites () =
  Alcotest.(check bool) "Composite_SMA_RSI in registry" true
    (Option.is_some (Strategies.Registry.find "Composite_SMA_RSI"));
  Alcotest.(check bool) "Composite_All in registry" true
    (Option.is_some (Strategies.Registry.find "Composite_All"))

let tests = [
  "unanimous all agree",     `Quick, test_unanimous_all_agree;
  "unanimous disagree",      `Quick, test_unanimous_disagree;
  "majority passes 2/3",     `Quick, test_majority_passes;
  "majority fails 1/3",      `Quick, test_majority_fails;
  "any single voter",        `Quick, test_any_single_voter;
  "exit beats enter",        `Quick, test_exit_beats_enter;
  "empty children hold",     `Quick, test_empty_children_hold;
  "registry has composites", `Quick, test_registry_has_composites;
]

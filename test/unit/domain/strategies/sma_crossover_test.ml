open Core

open Strategy_helpers

let build ~fast ~slow ~allow_short =
  let p = Strategies.Sma_crossover.{ fast; slow; allow_short } in
  Strategies.Strategy.make (module Strategies.Sma_crossover) p

let rising_then_falling =
  (* Flat prefix so both SMAs initialize with fast = slow (diff = 0),
     then an uptrend forces fast above slow (Enter_long), then a
     downtrend dips fast below slow (Exit_long or Enter_short). *)
  let flat = List.init 15 (fun _ -> 100.) in
  let up = List.init 40 (fun i -> 100. +. float_of_int i) in
  let down = List.init 40 (fun i -> 140. -. float_of_int i) in
  flat @ up @ down

let test_flat_gives_hold () =
  let strat = build ~fast:5 ~slow:10 ~allow_short:false in
  let acts = actions_from_prices strat (List.init 30 (fun _ -> 100.)) in
  Alcotest.(check bool)
    "no enters on flat input" true
    (not (contains Signal.Enter_long acts));
  Alcotest.(check bool) "no exits either" true (not (contains Signal.Exit_long acts))

let test_uptrend_triggers_long_entry () =
  let strat = build ~fast:5 ~slow:10 ~allow_short:false in
  let flat = List.init 15 (fun _ -> 100.) in
  let up = List.init 40 (fun i -> 100. +. float_of_int i) in
  let acts = actions_from_prices strat (flat @ up) in
  Alcotest.(check bool)
    "enter_long fires on sustained uptrend" true
    (contains Signal.Enter_long acts)

let test_reversal_exits_long () =
  let strat = build ~fast:5 ~slow:10 ~allow_short:false in
  let acts = actions_from_prices strat rising_then_falling in
  Alcotest.(check bool) "enter_long fires" true (contains Signal.Enter_long acts);
  Alcotest.(check bool)
    "exit_long fires after reversal" true
    (contains Signal.Exit_long acts)

let test_reversal_flips_when_short_allowed () =
  let strat = build ~fast:5 ~slow:10 ~allow_short:true in
  let acts = actions_from_prices strat rising_then_falling in
  Alcotest.(check bool)
    "enter_short replaces exit_long" true
    (contains Signal.Enter_short acts);
  Alcotest.(check bool)
    "no plain exit_long when flipping" true
    (not (contains Signal.Exit_long acts))

let test_enter_long_fires_once_per_cross () =
  (* Once the fast/slow relationship stabilises, the strategy should
     only emit Hold — no repeated Enter_long every bar in the trend. *)
  let strat = build ~fast:5 ~slow:10 ~allow_short:false in
  let flat = List.init 15 (fun _ -> 100.) in
  let up = List.init 80 (fun i -> 100. +. float_of_int i) in
  let acts = actions_from_prices strat (flat @ up) in
  let enters = List.filter (fun a -> a = Signal.Enter_long) acts in
  Alcotest.(check int) "exactly one enter_long in a single trend" 1 (List.length enters)

let test_rejects_fast_ge_slow () =
  Alcotest.check_raises "fast=slow invalid"
    (Invalid_argument "SMA_Crossover: fast < slow") (fun () ->
      ignore (build ~fast:10 ~slow:10 ~allow_short:false));
  Alcotest.check_raises "fast>slow invalid"
    (Invalid_argument "SMA_Crossover: fast < slow") (fun () ->
      ignore (build ~fast:20 ~slow:10 ~allow_short:false))

let tests =
  [
    ("flat → hold", `Quick, test_flat_gives_hold);
    ("uptrend triggers enter_long", `Quick, test_uptrend_triggers_long_entry);
    ("reversal exits long", `Quick, test_reversal_exits_long);
    ("reversal flips to short", `Quick, test_reversal_flips_when_short_allowed);
    ("enter fires once per trend", `Quick, test_enter_long_fires_once_per_cross);
    ("rejects fast >= slow", `Quick, test_rejects_fast_ge_slow);
  ]

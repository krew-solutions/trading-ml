open Core

open Strategy_helpers

let build ?(period = 20) ?(k = 2.0) ?(allow_short = true) () =
  let p = Strategies.Bollinger_breakout.{ period; k; allow_short } in
  Strategies.Strategy.make (module Strategies.Bollinger_breakout) p

(** Flat window establishes the Bollinger bands, then one very wide
    step pushes close above the upper band, triggering enter_long. *)
let flat_then_spike_up = List.init 25 (fun _ -> 100.) @ [ 150. ]

let flat_then_spike_down = List.init 25 (fun _ -> 100.) @ [ 50. ]

let test_spike_above_band_enters_long () =
  let strat = build ~allow_short:false () in
  let acts = actions_from_prices strat flat_then_spike_up in
  Alcotest.(check bool)
    "enter_long on spike above upper band" true
    (contains Signal.Enter_long acts)

let test_spike_below_band_enters_short () =
  let strat = build ~allow_short:true () in
  let acts = actions_from_prices strat flat_then_spike_down in
  Alcotest.(check bool)
    "enter_short on spike below lower band" true
    (contains Signal.Enter_short acts)

let test_reversion_to_middle_exits () =
  (* Spike up → long; then prices revert and drop below the middle
     band → exit_long. *)
  let up = List.init 25 (fun _ -> 100.) @ [ 150. ] in
  let revert = List.init 30 (fun _ -> 80.) in
  let strat = build ~allow_short:false () in
  let acts = actions_from_prices strat (up @ revert) in
  Alcotest.(check bool) "enter_long fires" true (contains Signal.Enter_long acts);
  Alcotest.(check bool)
    "exit_long fires when close reverts below middle" true
    (contains Signal.Exit_long acts)

let test_flat_input_silent () =
  let strat = build () in
  let acts = actions_from_prices strat (List.init 40 (fun _ -> 100.)) in
  Alcotest.(check bool)
    "no entries on constant prices" true
    (not (contains Signal.Enter_long acts));
  Alcotest.(check bool) "no shorts either" true (not (contains Signal.Enter_short acts))

let tests =
  [
    ("spike above → enter_long", `Quick, test_spike_above_band_enters_long);
    ("spike below → enter_short", `Quick, test_spike_below_band_enters_short);
    ("reversion → exit_long", `Quick, test_reversion_to_middle_exits);
    ("flat input stays silent", `Quick, test_flat_input_silent);
  ]

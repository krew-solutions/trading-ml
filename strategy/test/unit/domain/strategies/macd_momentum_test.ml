open Core

open Strategy_helpers

let build ?(fast = 12) ?(slow = 26) ?(signal = 9) ?(allow_short = false) () =
  let p = Strategies.Macd_momentum.{ fast; slow; signal; allow_short } in
  Strategies.Strategy.make (module Strategies.Macd_momentum) p

(** Price series with a clear regime change: flat then upward trend.
    MACD histogram should flip from ≤0 to >0 mid-series, triggering
    enter_long. *)
let flat_then_up =
  List.init 40 (fun _ -> 100.) @ List.init 60 (fun i -> 100. +. float_of_int i)

let test_histogram_flip_up_enters_long () =
  let strat = build () in
  let acts = actions_from_prices strat flat_then_up in
  Alcotest.(check bool)
    "enter_long on histogram flip +" true
    (contains Signal.Enter_long acts)

(* Flat prefix seeds MACD at 0, then up trend drives histogram positive
   (Enter_long), then down trend flips it negative (Exit_long / short). *)
let flat_up_down =
  List.init 40 (fun _ -> 100.)
  @ List.init 60 (fun i -> 100. +. float_of_int i)
  @ List.init 60 (fun i -> 160. -. float_of_int i)

let test_flip_down_exits_long () =
  let strat = build () in
  let acts = actions_from_prices strat flat_up_down in
  Alcotest.(check bool) "enter_long fires" true (contains Signal.Enter_long acts);
  Alcotest.(check bool)
    "exit_long fires on reversal" true
    (contains Signal.Exit_long acts)

let test_flip_to_short_when_allowed () =
  let strat = build ~allow_short:true () in
  let acts = actions_from_prices strat flat_up_down in
  Alcotest.(check bool) "short replaces exit_long" true (contains Signal.Enter_short acts)

let tests =
  [
    ("hist flip +  → enter_long", `Quick, test_histogram_flip_up_enters_long);
    ("hist flip -  → exit_long", `Quick, test_flip_down_exits_long);
    ("flip to short (allowed)", `Quick, test_flip_to_short_when_allowed);
  ]

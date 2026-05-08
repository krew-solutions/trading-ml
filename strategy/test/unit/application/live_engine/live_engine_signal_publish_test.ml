(** Unit tests for the post-M5 alpha-only {!Live_engine}.

    The legacy [live_engine_test.ml] exercised reservation lifecycle,
    kill-switch, rate-limit, broker submission, fill events,
    reconcile — all of which moved out of Strategy. These minimal
    cases pin the surviving contract: bars in, signals out
    (published as Signal_detected_IE via the injected port). *)

open Core
module Signal_detected = Strategy_integration_events.Signal_detected_integration_event

(* A trivial strategy that emits a fixed action on every bar.
   The action is carried inside [state] so the existential wrapper
   can route it through [on_candle] without exposing the parameter
   type. *)
module Fixed_signal_strategy = struct
  type params = { action : Common.Signal.action }
  type state = params

  let name = "Fixed"
  let default_params = { action = Common.Signal.Hold }
  let init p = p

  let on_candle (state : state) (instrument : Instrument.t) (c : Candle.t) =
    let sig_ : Common.Signal.t =
      {
        action = state.action;
        instrument;
        strength = 0.7;
        ts = c.ts;
        stop_loss = None;
        take_profit = None;
        reason = "fixed";
      }
    in
    (state, sig_)
end

let make_strategy_with_action action : Strategies.Strategy.t =
  Strategies.Strategy.make (module Fixed_signal_strategy) { Fixed_signal_strategy.action }

let candle ts close : Candle.t =
  let d = Decimal.of_string in
  Candle.make ~ts ~open_:(d "100") ~high:(d "101") ~low:(d "99")
    ~close:(d (string_of_int close))
    ~volume:(d "10")

let instrument = Instrument.of_qualified "SBER@MISX"

let make_engine ~strategy ~published =
  let publish_signal_detected (ie : Signal_detected.t) = published := ie :: !published in
  Live_engine.make
    ~config:{ strategy; instrument; strategy_id = "fixed-strat" }
    ~publish_signal_detected

let test_hold_signal_does_not_publish () =
  let strat = make_strategy_with_action Common.Signal.Hold in
  let published = ref [] in
  let engine = make_engine ~strategy:strat ~published in
  Live_engine.on_bar engine (candle 1L 100);
  Alcotest.(check int) "no IE" 0 (List.length !published)

let test_enter_long_publishes_up () =
  let strat = make_strategy_with_action Common.Signal.Enter_long in
  let published = ref [] in
  let engine = make_engine ~strategy:strat ~published in
  Live_engine.on_bar engine (candle 1L 100);
  match !published with
  | [ ie ] ->
      Alcotest.(check string) "direction" "UP" ie.direction;
      Alcotest.(check string) "strategy_id" "fixed-strat" ie.strategy_id;
      Alcotest.(check string) "ticker" "SBER" ie.instrument.ticker
  | _ -> Alcotest.fail "expected exactly one IE"

let test_enter_short_publishes_down () =
  let strat = make_strategy_with_action Common.Signal.Enter_short in
  let published = ref [] in
  let engine = make_engine ~strategy:strat ~published in
  Live_engine.on_bar engine (candle 1L 100);
  match !published with
  | [ ie ] -> Alcotest.(check string) "direction" "DOWN" ie.direction
  | _ -> Alcotest.fail "expected one IE"

let test_exit_long_publishes_flat_alpha_expiry () =
  let strat = make_strategy_with_action Common.Signal.Exit_long in
  let published = ref [] in
  let engine = make_engine ~strategy:strat ~published in
  Live_engine.on_bar engine (candle 1L 100);
  match !published with
  | [ ie ] -> Alcotest.(check string) "direction" "FLAT" ie.direction
  | _ -> Alcotest.fail "expected one IE"

let test_older_bar_is_dropped () =
  let strat = make_strategy_with_action Common.Signal.Enter_long in
  let published = ref [] in
  let engine = make_engine ~strategy:strat ~published in
  Live_engine.on_bar engine (candle 5L 100);
  Live_engine.on_bar engine (candle 4L 100);
  Alcotest.(check int) "only newer bar published" 1 (List.length !published)

let tests =
  [
    Alcotest.test_case "Hold does not publish" `Quick test_hold_signal_does_not_publish;
    Alcotest.test_case "Enter_long → UP" `Quick test_enter_long_publishes_up;
    Alcotest.test_case "Enter_short → DOWN" `Quick test_enter_short_publishes_down;
    Alcotest.test_case "Exit_long → FLAT" `Quick
      test_exit_long_publishes_flat_alpha_expiry;
    Alcotest.test_case "older-or-equal bar is dropped" `Quick test_older_bar_is_dropped;
  ]

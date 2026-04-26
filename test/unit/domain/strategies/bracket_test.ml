(** Tests for [Bracket] decorator.

    Strategy: wrap a deterministic stub as the inner entry source
    so the test controls exactly when [Enter_long] / [Enter_short]
    fires. Then drive OHLC candles through the decorator and
    assert on exit reasons and entry-signal enrichment. *)

open Core

open Strategy_helpers

(** Stub inner strategy — emits a fixed action on every bar.
    Same shape as the one in [composite_test], duplicated here
    so the two test files don't share implementation details. *)
module Stub = struct
  type state = Signal.action * float
  type params = state
  let name = "Stub"
  let default_params = (Signal.Hold, 0.0)
  let init p = p
  let on_candle (action, strength) instrument (c : Candle.t) =
    ( (action, strength),
      {
        Signal.ts = c.ts;
        instrument;
        action;
        strength;
        stop_loss = None;
        take_profit = None;
        reason = "stub";
      } )
end

let mk_stub action strength = Strategies.Strategy.make (module Stub) (action, strength)

let build_bracket
    ?(tp_mult = 1.5)
    ?(sl_mult = 1.0)
    ?(max_hold_bars = 20)
    ?(atr_period = 14)
    inner =
  let params =
    Strategies.Bracket.{ tp_mult; sl_mult; max_hold_bars; atr_period; inner }
  in
  Strategies.Strategy.make (module Strategies.Bracket) params

(** OHLC candle with independent control of close and high/low —
    close feeds the inner strategy's view of price, high/low drive
    the bracket-trigger decisions. *)
let ohlc_bar ~ts ~close ~high ~low =
  Candle.make ~ts:(Int64.of_int ts) ~open_:(Decimal.of_float close)
    ~high:(Decimal.of_float high) ~low:(Decimal.of_float low)
    ~close:(Decimal.of_float close) ~volume:(Decimal.of_int 1000)

(** Narrow-range warmup: [n] bars with close=100, range ±0.3, so
    Wilder ATR(14) converges to 0.6. That gives predictable TP/SL
    levels (TP = 100 + 1.5·0.6 = 100.9, SL = 100 − 1·0.6 = 99.4)
    for tests that need to place wide-range trigger bars after
    entry. *)
let warmup_bars ~n =
  List.init n (fun i -> ohlc_bar ~ts:i ~close:100.0 ~high:100.3 ~low:99.7)

(** Fold candles through the decorator, collecting (action, reason)
    pairs. Reasons matter because bracket exits and passthrough
    exits look identical at the action level. *)
let actions_with_reasons strat candles =
  let _, acc =
    List.fold_left
      (fun (s, acc) c ->
        let s', sig_ = Strategies.Strategy.on_candle s inst c in
        (s', (sig_.Signal.action, sig_.reason) :: acc))
      (strat, []) candles
  in
  List.rev acc

(** Same, but also retain the full Signal.t so tests can inspect
    TP/SL on the entry signal. *)
let signals_from strat candles =
  let _, acc =
    List.fold_left
      (fun (s, acc) c ->
        let s', sig_ = Strategies.Strategy.on_candle s inst c in
        (s', sig_ :: acc))
      (strat, []) candles
  in
  List.rev acc

let test_tp_exit () =
  (* Inner always fires Enter_long. Warmup primes ATR → first
     post-warmup bar transitions to Long. Next bar's high spikes
     above TP (100 + 1.5·0.6 = 100.9) → Exit_long with "TP hit". *)
  let strat = build_bracket (mk_stub Signal.Enter_long 0.9) in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ [ ohlc_bar ~ts:16 ~close:101.0 ~high:150.0 ~low:100.5 ]
  in
  let reasons = actions_with_reasons strat candles in
  let tp_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_long && r = "TP hit") reasons
  in
  Alcotest.(check bool) "Exit_long with TP-hit reason" true tp_exit

let test_sl_exit () =
  (* Same setup; down-spike below SL (100 − 1·0.6 = 99.4). *)
  let strat = build_bracket (mk_stub Signal.Enter_long 0.9) in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ [ ohlc_bar ~ts:16 ~close:99.5 ~high:100.0 ~low:50.0 ]
  in
  let reasons = actions_with_reasons strat candles in
  let sl_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_long && r = "SL hit") reasons
  in
  Alcotest.(check bool) "Exit_long with SL-hit reason" true sl_exit

let test_tie_sl_wins () =
  (* Bar whose range crosses both TP and SL — SL must win.
     Convention matches {!Ml.Triple_barrier.label}. *)
  let strat = build_bracket (mk_stub Signal.Enter_long 0.9) in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ [ ohlc_bar ~ts:16 ~close:100.0 ~high:200.0 ~low:0.0 ]
  in
  let reasons = actions_with_reasons strat candles in
  let sl_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_long && r = "SL hit") reasons
  in
  let tp_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_long && r = "TP hit") reasons
  in
  Alcotest.(check bool) "SL wins the tie-break" true sl_exit;
  Alcotest.(check bool) "TP does not fire on tie" false tp_exit

let test_timeout_exit () =
  (* Narrow bars inside the bracket after entry trigger neither
     TP nor SL; [max_hold_bars=5] forces an "timeout" exit. *)
  let strat = build_bracket ~max_hold_bars:5 (mk_stub Signal.Enter_long 0.9) in
  let post_entry =
    List.init 10 (fun i -> ohlc_bar ~ts:(16 + i) ~close:100.0 ~high:100.05 ~low:99.95)
  in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ post_entry
  in
  let reasons = actions_with_reasons strat candles in
  let timeout_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_long && r = "timeout") reasons
  in
  Alcotest.(check bool) "Exit_long with timeout reason" true timeout_exit

let test_priority_ignores_inner_while_in_position () =
  (* Inner keeps emitting Enter_long every bar. While we're in a
     position the decorator must suppress that and emit Hold
     (no repeated Enter_long, no early Exit_long on any grounds
     — only TP / SL / timeout decide). *)
  let strat = build_bracket ~max_hold_bars:100 (mk_stub Signal.Enter_long 0.9) in
  let post_entry =
    List.init 20 (fun i -> ohlc_bar ~ts:(16 + i) ~close:100.0 ~high:100.05 ~low:99.95)
  in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ post_entry
  in
  let reasons = actions_with_reasons strat candles in
  let enters = List.filter (fun (a, _) -> a = Signal.Enter_long) reasons in
  let exits = List.filter (fun (a, _) -> a = Signal.Exit_long) reasons in
  Alcotest.(check int) "exactly one Enter_long" 1 (List.length enters);
  Alcotest.(check int) "no Exit_long in quiet range" 0 (List.length exits)

let test_entry_carries_tp_sl () =
  (* The Enter_long signal the decorator emits must carry
     populated stop_loss / take_profit — downstream consumers
     (broker / engine / logging) rely on them. *)
  let strat = build_bracket (mk_stub Signal.Enter_long 0.9) in
  let candles =
    warmup_bars ~n:15 @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
  in
  let sigs = signals_from strat candles in
  let entries = List.filter (fun (s : Signal.t) -> s.action = Signal.Enter_long) sigs in
  match entries with
  | [] -> Alcotest.fail "no Enter_long emitted after ATR warmup"
  | s :: _ ->
      Alcotest.(check bool) "stop_loss populated" true (Option.is_some s.stop_loss);
      Alcotest.(check bool) "take_profit populated" true (Option.is_some s.take_profit)

let test_atr_warmup_swallows_entry () =
  (* During ATR warmup the decorator cannot size the bracket, so
     inner's Enter_long must be swallowed (Hold emitted) rather
     than fired naked. *)
  let strat = build_bracket (mk_stub Signal.Enter_long 0.9) in
  let candles =
    (* 10 bars is well below the ATR period of 14 — warmup is
       still active throughout. *)
    warmup_bars ~n:10
  in
  let reasons = actions_with_reasons strat candles in
  let enters = List.filter (fun (a, _) -> a = Signal.Enter_long) reasons in
  Alcotest.(check int) "no entry fired during ATR warmup" 0 (List.length enters)

let test_flat_inner_hold_passthrough () =
  (* When inner emits Hold and we're Flat, the decorator must
     pass it through rather than swallow it. *)
  let strat = build_bracket (mk_stub Signal.Hold 0.0) in
  let candles = warmup_bars ~n:20 in
  let sigs = signals_from strat candles in
  let non_holds = List.filter (fun (s : Signal.t) -> s.action <> Signal.Hold) sigs in
  Alcotest.(check int) "only Hold emitted when inner is Hold" 0 (List.length non_holds)

let test_short_tp_exit () =
  (* Short-side symmetry: TP is BELOW entry for shorts, SL is
     ABOVE. Down-spike past TP → Exit_short with "TP hit". *)
  let strat = build_bracket (mk_stub Signal.Enter_short 0.9) in
  let candles =
    warmup_bars ~n:15
    @ [ ohlc_bar ~ts:15 ~close:100.0 ~high:100.3 ~low:99.7 ]
    @ [ ohlc_bar ~ts:16 ~close:99.0 ~high:99.5 ~low:50.0 ]
  in
  let reasons = actions_with_reasons strat candles in
  let tp_exit =
    List.exists (fun (a, r) -> a = Signal.Exit_short && r = "TP hit") reasons
  in
  Alcotest.(check bool) "Exit_short with TP-hit reason" true tp_exit

let test_params_validated () =
  let mk ~tp ~sl ~max_hold ~atr_p () =
    let params =
      Strategies.Bracket.
        {
          tp_mult = tp;
          sl_mult = sl;
          max_hold_bars = max_hold;
          atr_period = atr_p;
          inner = mk_stub Signal.Hold 0.0;
        }
    in
    fun () -> ignore (Strategies.Strategy.make (module Strategies.Bracket) params)
  in
  Alcotest.check_raises "tp_mult must be > 0" (Invalid_argument "Bracket: tp_mult > 0")
    (mk ~tp:0.0 ~sl:1.0 ~max_hold:20 ~atr_p:14 ());
  Alcotest.check_raises "sl_mult must be > 0" (Invalid_argument "Bracket: sl_mult > 0")
    (mk ~tp:1.5 ~sl:(-0.5) ~max_hold:20 ~atr_p:14 ());
  Alcotest.check_raises "max_hold_bars must be > 0"
    (Invalid_argument "Bracket: max_hold_bars > 0")
    (mk ~tp:1.5 ~sl:1.0 ~max_hold:0 ~atr_p:14 ());
  Alcotest.check_raises "atr_period must be > 1"
    (Invalid_argument "Bracket: atr_period > 1")
    (mk ~tp:1.5 ~sl:1.0 ~max_hold:20 ~atr_p:1 ())

let tests =
  [
    ("TP exit", `Quick, test_tp_exit);
    ("SL exit", `Quick, test_sl_exit);
    ("tie: SL wins", `Quick, test_tie_sl_wins);
    ("timeout exit", `Quick, test_timeout_exit);
    ( "bracket ignores inner in position",
      `Quick,
      test_priority_ignores_inner_while_in_position );
    ("entry signal carries TP/SL", `Quick, test_entry_carries_tp_sl);
    ("ATR warmup swallows entry", `Quick, test_atr_warmup_swallows_entry);
    ("flat inner Hold passthrough", `Quick, test_flat_inner_hold_passthrough);
    ("short TP exit", `Quick, test_short_tp_exit);
    ("params validated", `Quick, test_params_validated);
  ]

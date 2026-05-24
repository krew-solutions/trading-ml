(** Unit tests for {!Pair_kalman_mean_reversion}: the policy
    wraps the Kalman state machine with the Pair_direction
    hysteresis and an intent builder. Tests here exercise the
    policy-level behaviour; pure Kalman update properties live in
    [kalman_dlm_state_test]. *)

open Core
module Pm = Portfolio_management
module PKM = Pm.Pair_kalman_mean_reversion
module Common = Pm.Common
module CI = Common.Construction_intent

let book = Common.Book_id.of_string "kalman-book"

let inst sym = Instrument.of_qualified sym
let sber = inst "SBER@MISX"
let lkoh = inst "LKOH@MISX"

let candle ~ts ~close =
  Candle.make ~ts ~open_:close ~high:close ~low:close ~close ~volume:Decimal.one

let make_config
    ?(discount = "0.99")
    ?(v = "0.0001")
    ?(z_entry = 2.0)
    ?(z_exit = 0.5)
    ?(burn_in = 0)
    ?(prior_alpha = "0.0")
    ?(prior_beta = "1.0")
    ?(prior_variance = "1.0")
    () =
  let pair = Common.Pair.make ~a:sber ~b:lkoh in
  PKM.Values.Kalman_dlm_config.make ~book_id:book ~pair
    ~discount:(Decimal.of_string discount) ~v:(Decimal.of_string v)
    ~z_entry:(Common.Z_score.of_float z_entry)
    ~z_exit:(Common.Z_score.of_float z_exit)
    ~burn_in
    ~prior_alpha:(Decimal.of_string prior_alpha)
    ~prior_beta:(Decimal.of_string prior_beta)
    ~prior_variance:(Decimal.of_string prior_variance)

let test_irrelevant_instrument_ignored () =
  let s = PKM.init (make_config ()) in
  let s', intent =
    PKM.on_bar s ~instrument:(inst "OTHER@MISX")
      ~candle:(candle ~ts:1L ~close:Decimal.one)
  in
  Alcotest.(check int)
    "bars_observed unchanged" 0
    (PKM.Values.Kalman_dlm_state.bars_observed s');
  Alcotest.(check bool) "no intent" true (Option.is_none intent)

let test_burn_in_respected () =
  let cfg = make_config ~burn_in:10 ~z_entry:0.5 ~z_exit:0.1 () in
  let s = ref (PKM.init cfg) in
  let intents = ref 0 in
  for k = 1 to 8 do
    let ts = Int64.of_int k in
    let close = Decimal.of_int (100 + (k * 5)) in
    let s', i_opt = PKM.on_bar !s ~instrument:sber ~candle:(candle ~ts ~close) in
    if Option.is_some i_opt then incr intents;
    let s'', i_opt' =
      PKM.on_bar s' ~instrument:lkoh
        ~candle:(candle ~ts:(Int64.add ts 1L) ~close:(Decimal.of_int 100))
    in
    if Option.is_some i_opt' then incr intents;
    s := s''
  done;
  Alcotest.(check int) "no intents emitted before burn_in completes" 0 !intents

let test_intent_carries_kalman_source () =
  (* Aggressively low thresholds and small burn-in so the filter
     trips within a few bars on synthetic data. *)
  let cfg = make_config ~z_entry:0.5 ~z_exit:0.1 ~burn_in:2 () in
  let s = ref (PKM.init cfg) in
  let captured = ref None in
  let drive k =
    let ts = Int64.of_int k in
    let close_a = Decimal.of_float (100.0 +. (5.0 *. float_of_int k)) in
    let close_b = Decimal.of_int 100 in
    let s', _ = PKM.on_bar !s ~instrument:sber ~candle:(candle ~ts ~close:close_a) in
    let s'', i_opt =
      PKM.on_bar s' ~instrument:lkoh ~candle:(candle ~ts:(Int64.add ts 1L) ~close:close_b)
    in
    s := s'';
    if Option.is_some i_opt && Option.is_none !captured then captured := i_opt
  in
  for k = 1 to 30 do
    drive k
  done;
  match !captured with
  | None ->
      Alcotest.fail
        "expected at least one intent under aggressive thresholds; check synthetic seed"
  | Some (CI.Coupled c) ->
      let expected_pair = Common.Pair.make ~a:sber ~b:lkoh in
      let is_kalman_source =
        match c.source with
        | Common.Source.Pair_kalman_mean_reversion p -> Common.Pair.equal p expected_pair
        | _ -> false
      in
      Alcotest.(check bool) "source is Pair_kalman_mean_reversion" true is_kalman_source;
      Alcotest.(check int) "two legs" 2 (List.length c.legs);
      let mentions i =
        List.exists (fun (l : CI.leg) -> Instrument.equal l.instrument i) c.legs
      in
      Alcotest.(check bool) "SBER mentioned" true (mentions sber);
      Alcotest.(check bool) "LKOH mentioned" true (mentions lkoh)
  | Some (CI.Scalar _) -> Alcotest.fail "expected Coupled intent"

let tests =
  [
    Alcotest.test_case "irrelevant instrument is ignored" `Quick
      test_irrelevant_instrument_ignored;
    Alcotest.test_case "burn_in suppresses signals" `Quick test_burn_in_respected;
    Alcotest.test_case "intent carries Pair_kalman_mean_reversion source" `Quick
      test_intent_carries_kalman_source;
  ]

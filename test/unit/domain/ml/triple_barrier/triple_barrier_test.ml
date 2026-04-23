(** Unit tests for {!Triple_barrier.label}.

    The labeler walks forward from an anchor bar [i] and returns
    the class of whichever barrier (TP / SL / timeout) fires
    first. Tests construct small candle arrays with deliberate
    high/low patterns so we know exactly which barrier should
    win, and assert the labeler picks the same one.

    For these tests we fix the ATR value manually (rather than
    letting the indicator warm up) so the test cases focus on the
    labeler's walk logic, not on ATR's computation. *)

open Core

(** Candle whose [high] and [low] can be set independently of
    [close] — essential for driving the barrier-crossing paths.
    [ts] starts at 1000 so different tests can be diffed without
    timestamp clashes. *)
let bar ~ts ~close ~high ~low =
  Candle.make
    ~ts:(Int64.of_int ts)
    ~open_:(Decimal.of_float close)
    ~high:(Decimal.of_float high)
    ~low:(Decimal.of_float low)
    ~close:(Decimal.of_float close)
    ~volume:(Decimal.of_int 1000)

(** ATR array where every bar has the same constant ATR; simpler
    than running the indicator. [0] means "not warmed up". *)
let constant_atr ~n ~value =
  Array.make n (Some value)

let test_tp_hit_first () =
  (* Anchor close=100, ATR=1.0, TP=+2 (=102), SL=-1 (=99).
     Bar 1: high=101  → no barrier touched
     Bar 2: high=103  → TP! Label 2. *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:100.5 ~high:101.0 ~low:99.8;
    bar ~ts:2 ~close:102.5 ~high:103.0 ~low:100.0;
    bar ~ts:3 ~close:103.0 ~high:103.5 ~low:102.5;
    bar ~ts:4 ~close:103.0 ~high:103.5 ~low:102.5;
  |] in
  let atr = constant_atr ~n:5 ~value:1.0 in
  Alcotest.(check (option int)) "TP hit at bar 2 → class 2"
    (Some 2)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:4)

let test_sl_hit_first () =
  (* Same anchor, but now a downside path hits SL before TP. *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:99.5  ~high:100.0 ~low:98.5;   (* SL=99 hit *)
    bar ~ts:2 ~close:98.0  ~high:99.0  ~low:97.0;
    bar ~ts:3 ~close:97.0  ~high:98.0  ~low:96.0;
    bar ~ts:4 ~close:96.0  ~high:97.0  ~low:95.0;
  |] in
  let atr = constant_atr ~n:5 ~value:1.0 in
  Alcotest.(check (option int)) "SL hit at bar 1 → class 0"
    (Some 0)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:4)

let test_timeout_neither_hit () =
  (* Path stays inside [99, 102] for the whole window → class 1. *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:100.5 ~high:101.0 ~low:99.8;
    bar ~ts:2 ~close:100.0 ~high:101.5 ~low:99.2;
    bar ~ts:3 ~close:100.3 ~high:101.0 ~low:99.7;
    bar ~ts:4 ~close:100.1 ~high:100.5 ~low:99.5;
  |] in
  let atr = constant_atr ~n:5 ~value:1.0 in
  Alcotest.(check (option int)) "no barrier hit → class 1"
    (Some 1)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:4)

let test_both_hit_same_bar_sl_wins () =
  (* Single wide-range bar whose [low, high] straddles both TP
     and SL simultaneously: intra-bar order unknowable, convention
     is SL-first (conservative). *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:100.0 ~high:103.0 ~low:98.0;   (* spans TP=102 AND SL=99 *)
  |] in
  let atr = constant_atr ~n:2 ~value:1.0 in
  Alcotest.(check (option int)) "both-hit → class 0 (SL-wins tie-break)"
    (Some 0)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:1)

let test_anchor_bar_itself_is_not_tested () =
  (* The walk starts at [i + 1]; barrier touches on bar [i] are
     not counted (we entered AT close[i], so the bar is "behind us"
     already). Verify by constructing bar 0 with an intra-bar high
     that would hit TP if counted — it shouldn't be. *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:103.0 ~low:99.0;   (* already past TP at entry close *)
    bar ~ts:1 ~close:99.1  ~high:99.5  ~low:98.5;   (* SL *)
  |] in
  let atr = constant_atr ~n:2 ~value:1.0 in
  Alcotest.(check (option int)) "bar [i] itself ignored; walk starts at i+1 → SL"
    (Some 0)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:1)

let test_atr_not_warmed_up () =
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:100.0 ~high:100.5 ~low:99.5;
  |] in
  let atr = [| None; None |] in
  Alcotest.(check (option int)) "no ATR → None"
    None
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:1)

let test_zero_atr_rejected () =
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:1 ~close:100.0 ~high:100.5 ~low:99.5;
  |] in
  let atr = [| Some 0.0; Some 0.0 |] in
  Alcotest.(check (option int)) "zero ATR → None (degenerate bands)"
    None
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:1)

let test_asymmetric_barriers () =
  (* Tighter SL (0.5×ATR) vs wider TP (3×ATR): now TP=103 and
     SL=99.5. A path to high=102 shouldn't hit TP but should
     leave SL at rest too. *)
  let arr = [|
    bar ~ts:0 ~close:100.0 ~high:100.5 ~low:99.6;
    bar ~ts:1 ~close:101.5 ~high:102.0 ~low:100.0;
    bar ~ts:2 ~close:101.5 ~high:102.0 ~low:100.0;
    bar ~ts:3 ~close:101.0 ~high:101.5 ~low:100.0;
  |] in
  let atr = constant_atr ~n:4 ~value:1.0 in
  Alcotest.(check (option int)) "asym: neither hit → class 1"
    (Some 1)
    (Triple_barrier.label ~arr ~atr ~i:0
       ~tp_mult:3.0 ~sl_mult:0.5 ~timeout:3)

let test_timeout_clipped_to_array_end () =
  (* Anchor at index 2, timeout=10 but array only has 4 bars →
     walker runs through bars 3 only, neither barrier touched. *)
  let arr = [|
    bar ~ts:0 ~close:99.0  ~high:99.5  ~low:98.5;
    bar ~ts:1 ~close:99.5  ~high:100.0 ~low:99.0;
    bar ~ts:2 ~close:100.0 ~high:100.5 ~low:99.5;
    bar ~ts:3 ~close:100.3 ~high:100.8 ~low:99.8;
  |] in
  let atr = constant_atr ~n:4 ~value:1.0 in
  Alcotest.(check (option int)) "partial window (short tail) → class 1"
    (Some 1)
    (Triple_barrier.label ~arr ~atr ~i:2
       ~tp_mult:2.0 ~sl_mult:1.0 ~timeout:10)

let tests = [
  "TP hit first",                    `Quick, test_tp_hit_first;
  "SL hit first",                    `Quick, test_sl_hit_first;
  "timeout neither hit",             `Quick, test_timeout_neither_hit;
  "both-hit same bar → SL wins",     `Quick, test_both_hit_same_bar_sl_wins;
  "anchor bar [i] ignored",          `Quick, test_anchor_bar_itself_is_not_tested;
  "ATR not warmed up → None",        `Quick, test_atr_not_warmed_up;
  "zero ATR → None",                 `Quick, test_zero_atr_rejected;
  "asymmetric barriers",             `Quick, test_asymmetric_barriers;
  "partial tail window",             `Quick, test_timeout_clipped_to_array_end;
]

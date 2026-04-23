(** Triple-barrier labelling for financial time-series supervised
    learning, after López de Prado, "Advances in Financial Machine
    Learning" (2018).

    For each bar [t], the label answers: if I opened a position at
    [close[t]] with symmetric take-profit / stop-loss barriers
    scaled by local volatility (ATR), which barrier (if any)
    fires first within a [timeout] window?

    Output classes (match the three-class schema downstream):
    - [2] — take-profit hit first (up)
    - [0] — stop-loss hit first (down)
    - [1] — neither hit before [timeout] (flat)

    Compared to a naive "sign of return at [t + horizon]" label
    this is path-sensitive (sees intra-window highs/lows, not just
    one future close) and volatility-adaptive (barriers scale with
    ATR). Both properties matter when the downstream model will
    trade with TP/SL brackets. *)

open Core

val label :
  arr:Candle.t array ->
  atr:float option array ->
  i:int ->
  tp_mult:float ->
  sl_mult:float ->
  timeout:int ->
  int option
(** [label ~arr ~atr ~i ~tp_mult ~sl_mult ~timeout] — compute the
    triple-barrier class for bar index [i]. Returns [None] when
    ATR hasn't warmed up at [i] or is non-positive (degenerate —
    barriers would coincide). The caller is expected to skip bars
    where [i + timeout >= Array.length arr], since the forward
    walk needs a full window.

    Tie-break: when a single bar's [low..high] range straddles
    both TP and SL simultaneously, we assume SL fired first. This
    is the conservative convention used throughout de Prado's
    literature — it biases the labeler against falsely optimistic
    [TP] calls on gappy / wide-range bars where intra-bar order
    is unknowable. *)

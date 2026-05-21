(** Immediate execution strategy — the baseline: one placement
    carries the trader's full [total_quantity] at construction and
    the strategy waits passively for the broker's terminal verdict.

    Lifecycle:
    - {!init} returns a state in which the single placement is
      pending plus a [Decision] with one [submit_request] of
      [Σ submit = total_quantity].
    - {!on_event} reacts only to broker-derived events on that
      placement:
        * [Placement_acknowledged] — kept; strategy continues.
        * [Placement_filled] (with fill quantity = total) — state
          becomes complete; terminal = [Completed].
        * [Placement_rejected] / [Placement_unreachable] — state
          becomes failed; terminal = [Failed _].
        * [Placement_cancelled] — state becomes failed (an
          operator cancel between submit and fill terminates the
          strategy without further work).
      All other inputs ([Tick], etc.) are ignored: [Decision.empty]
      with state unchanged.

    Invariants:
    - The initial [Decision.submit] list has exactly one element
      whose quantity equals [intent.total_quantity].
    - The strategy never proposes additional submits after init
      (Immediate is one-shot by design — partial fills do not
      refill, the aggregate's strategy can be replaced if the
      user wants retry-on-partial semantics). *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type state
(** Private — internal lifecycle stage tracked by the strategy. *)

val init : intent:Values.Trade_intent.t -> now:int64 -> state * Decision.t
(** Construct the initial state and the first decision (one
    submit covering the full intent). [now] is reserved for
    determinism / parity with time-driven strategies; Immediate
    does not consult the clock. *)
(*@ s, d = init ~intent ~now
    ensures List.length d.Decision.submit = 1
    ensures (match d.Decision.submit with
             | r :: _ -> dec_raw r.Decision.quantity = dec_raw intent.Values.Trade_intent.total_quantity
             | [] -> false)
    ensures d.Decision.cancel = []
    ensures d.Decision.terminal = Decision.Continue *)

val on_event : state -> Input.t -> now:int64 -> state * Decision.t
(** Translate a strategy input into a new state and any next-step
    decision. Immediate emits [Decision.empty] for every input
    other than the four placement-terminal events on its single
    pending placement. *)

val is_complete : state -> bool
(** [true] once the placement has been observed filled in full. *)

(** Strategy — the closed-variant dispatcher across every concrete
    execution strategy in the BC. The variant is the abstraction's
    enforcement mechanism: adding a strategy is a compiler-guided
    refactor (every match site fails until the new constructor is
    handled), not a runtime surprise.

    The {!t} sum type carries each strategy's private [state]. The
    top-level functions [init] / [on_event] / [is_complete]
    dispatch by exhaustive [match], forwarding to the concrete
    strategy module. Strategies share the {!Input} input alphabet
    and the {!Decision} output alphabet; per-strategy state types
    remain private to their own modules.

    PR1: only [Immediate] populates the variant. PR2 adds Twap /
    Vwap / Pov / Iceberg / Implementation_shortfall, each as
    additional [type t = ... | Twap of Twap.state | ...] cases.

    Strategy selection: the aggregate creates the initial [t] via
    {!init}, supplying the {!Values.Execution_directive.t} that
    came in from the trader intent (or the fallback [Immediate]
    from [Execution_policy]). *)

type t = Immediate of Immediate.state

val init :
  intent:Values.Trade_intent.t ->
  directive:Values.Execution_directive.t ->
  now:int64 ->
  t * Decision.t
(** Construct the initial strategy state for the chosen directive
    and emit the first decision. *)

val on_event : t -> Input.t -> now:int64 -> t * Decision.t
(** Forward an input to the active strategy and return its
    decision. *)

val is_complete : t -> bool
(** [true] iff the active strategy considers its work finished
    (all intended slices have settled). *)

(** Module type for portfolio construction policies.

    A construction policy is a state machine: it consumes candle
    bars for one or more instruments and occasionally emits a
    {!Common.Construction_intent.t} — a {b dimensionless}
    description of what the policy wants the book to hold.
    Sizing (converting weight to quantity) is the job of
    {!Sizing_policy} downstream; clipping is the job of
    {!Risk_policy.clip}. Policies own no I/O; they are pure state
    transitions.

    Each implementation defines its own [config] and [state]
    types — they vary across policies (pair_mean_reversion /
    β-hedge / vol_target / ...) and can't share a common shape
    without losing expressiveness. The module type fixes only the
    entry points: [name], [init], [on_bar]. *)

module type S = sig
  type config
  type state

  val name : string
  (** Stable identifier for the policy. *)

  val init : config -> state

  val on_bar :
    state ->
    instrument:Core.Instrument.t ->
    candle:Core.Candle.t ->
    state * Common.Construction_intent.t option
  (** Feed a candle for [instrument] into the policy. Returns the
      updated state and, if the policy decides to update its
      target, a {!Construction_intent.t}. [None] means: no
      target update warranted (insufficient history, irrelevant
      instrument, hysteresis hold). *)
end

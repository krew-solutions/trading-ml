(** Module type for portfolio construction policies.

    A construction policy is a state machine: it consumes candle bars
    for one or more instruments and occasionally emits a target proposal
    that the [Target_portfolio] aggregate applies to its book. Policies
    own no I/O; they are pure state transitions. The composition root
    pipes a candle stream into [on_bar] and routes any returned proposal
    through [Set_target_command].

    Each implementation defines its own [config] and [state] types —
    they vary across policies (pair_mean_reversion / β-hedge /
    vol_target / ...) and can't share a common shape without losing
    expressiveness. The module type fixes only the entry points:
    [name], [init], [on_bar]. *)

module type S = sig
  type config
  type state

  val name : string
  (** Stable identifier for the policy; copied into emitted proposals
      as [Target_proposal.source] for audit. *)

  val init : config -> state

  val on_bar :
    state ->
    instrument:Core.Instrument.t ->
    candle:Core.Candle.t ->
    state * Common.Target_proposal.t option
  (** Feed a candle for [instrument] into the policy. Returns the
      updated state and, if the policy decides to update its target,
      a [Target_proposal.t]. [None] means: no target update warranted
      (insufficient history, irrelevant instrument, hysteresis hold). *)
end

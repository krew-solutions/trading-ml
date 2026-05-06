(** Stateful inbound handler for {!Bar_updated_integration_event.t}
    that drives pair-mean-reversion policies registered against it.

    Unlike {!Strategy_inbound_integration_events.Bar_updated_integration_event_handler},
    this one is fully synchronous: there is no consumer fiber to
    feed, no [Eio.Stream] buffer. On each inbound bar the handler
    iterates the registered pair states, calls
    {!Portfolio_management.Pair_mean_reversion.on_bar} on each one
    whose pair contains the bar's instrument, mutates the state ref,
    and on [Some target_proposal] dispatches a
    {!Portfolio_management_commands.Set_target_command.t} through
    the supplied port.

    The registry starts empty. There is no caller for [register]
    today — when a [Define_pair_mr_command] (or analogous) lands,
    its workflow will populate this handler. Until then, every bar
    passes through with no side-effects (zero registered pairs). *)

type t

val make : unit -> t

val register : t -> Portfolio_management.Pair_mean_reversion.state ref -> unit
(** Add a pair-mr state ref to the registry. The state already
    carries its [Pair_mr_config] (book_id + pair + window +
    thresholds), so no separate identifying parameters are needed.
    The ref is mutated in place by {!handle} as bars arrive. *)

val handle :
  t ->
  dispatch_set_target:(Portfolio_management_commands.Set_target_command.t -> unit) ->
  Bar_updated_integration_event.t ->
  unit
(** Bus callback. For each registered pair whose instruments
    include the bar's instrument, advances the state via
    {!Pair_mean_reversion.on_bar} and dispatches a
    {!Set_target_command} on any emitted proposal. *)

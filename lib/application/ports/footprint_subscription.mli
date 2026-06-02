(** Hexagonal port: declare / release interest in a footprint feed
    keyed by [(symbol, boundary-token)].

    The footprint counterpart of {!Bar_subscription}. Application-layer
    abstraction over "tell the order_flow BC that I want footprints for
    this [(instrument, boundary)] built and flowing." The concrete adapter
    (in {!Server_external_commands}) serialises the call into
    {!Watch_footprints_command} / {!Unwatch_footprints_command} and
    publishes it onto the bus; the order_flow BC's command dispatcher
    picks it up and starts / stops fanning the public tape into that
    boundary on top of the operator's always-on default.

    Unlike {!Bar_subscription}, the arguments are raw strings, not
    domain-typed: the boundary token may be a volume cap ([VOL:1000]) that
    no {!Core.Timeframe.t} can hold, and the SSE footprint feed is itself
    string-keyed. Validation of the token back into a domain boundary is
    the order_flow command handler's concern, not this port's. *)

type t = {
  watch : symbol:string -> boundary:string -> unit;
  unwatch : symbol:string -> boundary:string -> unit;
}

val noop : t
(** Inert implementation — both fields no-op. Used as the default when no
    adapter is wired (e.g. backtest deployments that don't drive the live
    footprint demand at all). *)

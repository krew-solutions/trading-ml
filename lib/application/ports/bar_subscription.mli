(** Hexagonal port: declare / release interest in a bar feed
    keyed by [(instrument, timeframe)].

    Application-layer abstraction over "tell the broker BC that
    I want bars on this key flowing." The concrete adapter
    (in {!Server_external_commands}) serialises the call into
    {!Broker_commands.Watch_bars_command} / {!Unwatch_bars_command}
    and publishes it onto the bus; the broker BC's command
    dispatcher picks it up and forwards to {!Broker.subscribe} /
    {!Broker.unsubscribe} on its refcounted port.

    The port carries domain-typed arguments — wire-shape
    primitives are the adapter's concern. *)

open Core

type t = {
  watch : instrument:Instrument.t -> timeframe:Timeframe.t -> unit;
  unwatch : instrument:Instrument.t -> timeframe:Timeframe.t -> unit;
}

val noop : t
(** Inert implementation — both fields no-op. Used as the
    default when no adapter is wired (e.g. backtest deployments
    that don't open upstream feeds at all). *)

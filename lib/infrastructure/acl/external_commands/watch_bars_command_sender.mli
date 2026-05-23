(** Hexagonal Adapter: implements the [watch] half of
    {!Server_application_ports.Bar_subscription.t} by serialising
    each call into a {!Watch_bars_command.t} and publishing it on
    [in-memory://broker.watch-bars-command]. The broker BC's
    command dispatcher subscribes to that topic and forwards to
    {!Broker.subscribe} on its refcounted port.

    Domain-typed at the port surface ([Instrument.t],
    [Timeframe.t]); the wire-format primitives ([symbol],
    [timeframe] as strings) are constructed inside the closure
    via [Instrument.to_qualified] / [Timeframe.to_string]. *)

open Core

val make : bus:Bus.bus -> instrument:Instrument.t -> timeframe:Timeframe.t -> unit

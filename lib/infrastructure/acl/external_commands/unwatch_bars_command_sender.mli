(** Hexagonal Adapter: implements the [unwatch] half of
    {!Server_application_ports.Bar_subscription.t} by serialising
    each call into an {!Unwatch_bars_command.t} and publishing
    it on [in-memory://broker.unwatch-bars-command]. Counterpart
    to {!Watch_bars_command_sender.make}. *)

open Core

val make : bus:Bus.bus -> instrument:Instrument.t -> timeframe:Timeframe.t -> unit

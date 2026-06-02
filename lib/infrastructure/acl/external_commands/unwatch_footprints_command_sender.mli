(** Hexagonal Adapter: implements the [unwatch] half of
    {!Server_application_ports.Footprint_subscription.t} by serialising
    each call into an {!Unwatch_footprints_command.t} and publishing it on
    [in-memory://order-flow.unwatch-footprints-command]. The order_flow
    BC's command dispatcher subscribes to that topic and stops fanning the
    tape into that boundary on the last release (the always-on default
    keeps forming). *)

val make : bus:Bus.bus -> symbol:string -> boundary:string -> unit

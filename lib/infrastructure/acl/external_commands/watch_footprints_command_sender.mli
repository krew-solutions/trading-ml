(** Hexagonal Adapter: implements the [watch] half of
    {!Server_application_ports.Footprint_subscription.t} by serialising
    each call into a {!Watch_footprints_command.t} and publishing it on
    [in-memory://order-flow.watch-footprints-command]. The order_flow BC's
    command dispatcher subscribes to that topic and starts fanning the
    public tape into that boundary on top of the always-on default.

    String-typed at the port surface ([symbol], [boundary]) — the boundary
    token is opaque here (it may be a volume cap no [Timeframe.t] holds);
    order_flow validates it back into a domain boundary. *)

val make : bus:Bus.bus -> symbol:string -> boundary:string -> unit

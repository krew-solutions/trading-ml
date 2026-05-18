(** Live {!Volume_feed_port.S} adapter.

    The adapter is a passive callback registry: the ACL boundary
    ({!Bar_updated_integration_event_handler}) decodes broker bus
    bars into typed [Volume_bar.t] values and pushes them in via
    {!deliver}; the adapter then invokes every subscriber whose
    [instrument] and [timeframe] match.

    The adapter does not subscribe to the bus itself — bus
    plumbing stays in the factory. This keeps the adapter
    isolatable in unit tests that exercise [subscribe] /
    [unsubscribe] / [deliver] without standing up a bus. *)

type t
type subscription

val create : unit -> t

val subscribe :
  t ->
  instrument:Core.Instrument.t ->
  timeframe:string ->
  on_bar:(Execution_management.Order_ticket.Values.Volume_bar.t -> unit) ->
  subscription

val unsubscribe : t -> subscription -> unit

val deliver :
  t ->
  instrument:Core.Instrument.t ->
  timeframe:string ->
  bar:Execution_management.Order_ticket.Values.Volume_bar.t ->
  unit
(** Push a bar into the registry: invokes every subscriber whose
    [instrument] and [timeframe] match. Subscriber exceptions
    are caught so a single broken consumer cannot block others. *)

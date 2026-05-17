(** ACL handler: translates inbound
    {!Order_accepted_integration_event.t} (broker BC's outbound IE)
    into {!Apply_placement_acknowledgement_command.t} and invokes
    the workflow in-process. *)

val handle :
  store:(module Execution_management_ports.Ticket_store.S with type t = 'store) ->
  store_handle:'store ->
  publish:(Execution_management.Order_ticket.event -> unit) ->
  now:(unit -> int64) ->
  ticket_id_of_placement_id:(int -> int) ->
  Order_accepted_integration_event.t ->
  unit
(** [~ticket_id_of_placement_id] decodes the broker-side
    placement_id back to its owning ticket. Since the broker IE
    carries only [placement_id] (and not [ticket_id]), the
    factory supplies a closure that knows the wire-format
    encoding. *)

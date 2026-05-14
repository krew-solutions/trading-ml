(** Command pipeline for {!Submit_order_command.t}.

    Composes the parse/validate/persist step from
    {!Submit_order_command_handler.handle} with the domain-event
    publication from
    {!Paper_broker_domain_event_handlers.Publish_integration_event_on_order_accepted.handle}.

    On validation failure, publishes a
    {!Paper_broker_integration_events.Order_rejected_integration_event.t}
    carrying the round-trip [reservation_id] so the originating
    Account-side reservation can be released by its inbound ACL. *)

module Order_accepted :
    module type of Paper_broker_integration_events.Order_accepted_integration_event

module Order_rejected :
    module type of Paper_broker_integration_events.Order_rejected_integration_event

module type Store = Order_store.S

val execute :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  next_order_id:(unit -> string) ->
  now_ts:(unit -> int64) ->
  placed_after_ts:(Core.Instrument.t -> int64) ->
  publish_order_accepted:(Order_accepted.t -> unit) ->
  publish_order_rejected:(Order_rejected.t -> unit) ->
  Submit_order_command.t ->
  (unit, Submit_order_command_handler.handle_error) Rop.t

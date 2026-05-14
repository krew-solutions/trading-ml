module Order_cancelled = Paper_broker_integration_events.Order_cancelled_integration_event

module type Store = Order_store.S

let execute
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(now_ts : unit -> int64)
    ~(publish_order_cancelled : Order_cancelled.t -> unit)
    (cmd : Cancel_pending_order_command.t) :
    (unit, Cancel_pending_order_command_handler.handle_error) Rop.t =
  match Cancel_pending_order_command_handler.handle ~store ~store_handle ~now_ts cmd with
  | Ok { pending; event } ->
      Paper_broker_domain_event_handlers.Publish_integration_event_on_order_cancelled
      .handle ~publish_order_cancelled ~correlation_id:cmd.correlation_id
        ~reservation_id:pending.reservation_id event;
      Rop.succeed ()
  | Error errs -> Error errs

module Order_accepted = Paper_broker_integration_events.Order_accepted_integration_event

module Order_rejected = Paper_broker_integration_events.Order_rejected_integration_event

module type Store = Order_store.S

let execute
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(next_order_id : unit -> string)
    ~(now_ts : unit -> int64)
    ~(placed_after_ts : Core.Instrument.t -> int64)
    ~(publish_order_accepted : Order_accepted.t -> unit)
    ~(publish_order_rejected : Order_rejected.t -> unit)
    (cmd : Submit_order_command.t) :
    (unit, Submit_order_command_handler.handle_error) Rop.t =
  match
    Submit_order_command_handler.handle ~store ~store_handle ~next_order_id ~now_ts
      ~placed_after_ts cmd
  with
  | Ok (_pending, domain_event) ->
      Paper_broker_domain_event_handlers.Publish_integration_event_on_order_accepted
      .handle ~publish_order_accepted ~correlation_id:cmd.correlation_id
        ~reservation_id:cmd.reservation_id domain_event;
      Rop.succeed ()
  | Error errs ->
      let reasons =
        List.filter_map
          (function
            | Submit_order_command_handler.Validation v ->
                Some (Submit_order_command_handler.validation_error_to_string v))
          errs
      in
      let reason = String.concat "; " reasons in
      publish_order_rejected
        Order_rejected.
          {
            correlation_id = cmd.correlation_id;
            reservation_id = cmd.reservation_id;
            reason;
          };
      Error errs

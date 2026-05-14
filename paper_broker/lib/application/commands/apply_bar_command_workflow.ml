module Order_filled = Paper_broker_integration_events.Order_filled_integration_event

module type Store = Order_store.S

let execute
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(slippage_bps : Paper_broker.Slippage.Values.Slippage_bps.t)
    ~(fee_rate : Paper_broker.Fee.Values.Fee_rate.t)
    ~(participation_rate : Paper_broker.Matching.Values.Participation_rate.t option)
    ~(next_exec_id : unit -> string)
    ~(publish_order_filled : Order_filled.t -> unit)
    (cmd : Apply_bar_command.t) : (unit, Apply_bar_command_handler.handle_error) Rop.t =
  match
    Apply_bar_command_handler.handle ~store ~store_handle ~slippage_bps ~fee_rate
      ~participation_rate ~next_exec_id cmd
  with
  | Ok fills ->
      List.iter
        (fun (f : Apply_bar_command_handler.fill_outcome) ->
          Paper_broker_domain_event_handlers.Publish_integration_event_on_fill_observed
          .handle ~publish_order_filled ~correlation_id:f.pending.correlation_id
            ~reservation_id:f.pending.reservation_id f.event)
        fills;
      Rop.succeed ()
  | Error errs -> Error errs

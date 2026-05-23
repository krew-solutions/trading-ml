module Order_filled = Paper_broker_integration_events.Order_leg_filled_integration_event

module type Store = Paper_broker_store.Order_store.S
module type Command_log = Paper_broker_store.Order_command_log.S

let execute
    (type store log)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(command_log : (module Command_log with type t = log))
    ~(command_log_handle : log)
    ~(slippage_bps : Paper_broker.Slippage.Values.Slippage_bps.t)
    ~(fee_rate : Paper_broker.Fee.Values.Fee_rate.t)
    ~(participation_rate : Paper_broker.Matching.Values.Participation_rate.t option)
    ~(next_trade_id : unit -> string)
    ~(publish_order_filled : Order_filled.t -> unit)
    (cmd : Apply_bar_command.t) : (unit, Apply_bar_command_handler.handle_error) Rop.t =
  let module L = (val command_log : Command_log with type t = log) in
  match
    Apply_bar_command_handler.handle ~store ~store_handle ~slippage_bps ~fee_rate
      ~participation_rate ~next_trade_id cmd
  with
  | Ok fills ->
      List.iter
        (fun (f : Apply_bar_command_handler.fill_outcome) ->
          let correlation_id =
            match L.origin_correlation_id command_log_handle ~aggregate_id:f.order.id with
            | Some cid -> cid
            | None ->
                (* The order is in the store but has no submit-correlation
                   logged. Either the log was wiped (restart with persisted
                   store), or the order was inserted out-of-band. Emit with
                   empty correlation_id to keep the IE shape valid; downstream
                   sagas key by placement_id anyway. *)
                ""
          in
          Paper_broker_domain_event_handlers.Publish_integration_event_on_order_leg_filled
          .handle ~publish_order_filled ~correlation_id f.event)
        fills;
      Rop.succeed ()
  | Error errs -> Error errs

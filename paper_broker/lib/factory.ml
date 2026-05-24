open Core

type t = { http_handler : Inbound_http.Route.handler }

let build ~bus ~now ~slippage_bps ~fee_rate ?participation_rate () : t =
  let participation_rate : Paper_broker.Matching.Values.Participation_rate.t option =
    participation_rate
  in
  let store : Paper_broker_persistence.In_memory_order_store.t =
    Paper_broker_persistence.In_memory_order_store.create ()
  in
  let store_module =
    (module Paper_broker_persistence.In_memory_order_store
    : Paper_broker_store.Order_store.S
      with type t = Paper_broker_persistence.In_memory_order_store.t)
  in
  let command_log : Paper_broker_persistence.In_memory_order_command_log.t =
    Paper_broker_persistence.In_memory_order_command_log.create ()
  in
  let command_log_module =
    (module Paper_broker_persistence.In_memory_order_command_log
    : Paper_broker_store.Order_command_log.S
      with type t = Paper_broker_persistence.In_memory_order_command_log.t)
  in
  let next_order_id =
    let counter = ref 0 in
    fun () ->
      incr counter;
      Printf.sprintf "po-%d" !counter
  in
  let next_trade_id =
    let counter = ref 0 in
    fun () ->
      incr counter;
      Printf.sprintf "tr-%d" !counter
  in
  let now_ts = now in
  let last_seen_bar_ts : (Instrument.t, int64) Hashtbl.t = Hashtbl.create 16 in
  let placed_after_ts instrument =
    match Hashtbl.find_opt last_seen_bar_ts instrument with
    | Some ts -> ts
    | None -> 0L
  in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_order_accepted =
    produce ~uri:"in-memory://broker.order-accepted"
      ~yojson_of:
        Paper_broker_integration_events.Order_accepted_integration_event.yojson_of_t
  in
  let publish_order_filled =
    produce ~uri:"in-memory://broker.order-filled"
      ~yojson_of:
        Paper_broker_integration_events.Order_filled_integration_event.yojson_of_t
  in
  let publish_order_rejected =
    produce ~uri:"in-memory://broker.order-rejected"
      ~yojson_of:
        Paper_broker_integration_events.Order_rejected_integration_event.yojson_of_t
  in
  let publish_order_cancelled =
    produce ~uri:"in-memory://broker.order-cancelled"
      ~yojson_of:
        Paper_broker_integration_events.Order_cancelled_integration_event.yojson_of_t
  in
  let dispatch_submit_order (cmd : Paper_broker_commands.Submit_order_command.t) =
    match
      Paper_broker_commands.Submit_order_command_workflow.execute ~store:store_module
        ~store_handle:store ~command_log:command_log_module
        ~command_log_handle:command_log ~next_order_id ~now_ts ~placed_after_ts
        ~publish_order_accepted ~publish_order_rejected cmd
    with
    | Ok () -> ()
    | Error _ ->
        (* Validation failures already surfaced as Order_rejected IE
           by the workflow; the Rop tail is discarded. *)
        ()
  in
  let dispatch_apply_bar (cmd : Paper_broker_commands.Apply_bar_command.t) =
    let bar_ts_parsed = Datetime.Iso8601.parse cmd.candle.ts in
    (match
       Paper_broker_commands.Apply_bar_command_workflow.execute ~store:store_module
         ~store_handle:store ~command_log:command_log_module
         ~command_log_handle:command_log ~slippage_bps ~fee_rate ~participation_rate
         ~next_trade_id ~publish_order_filled cmd
     with
    | Ok () -> ()
    | Error _ -> ());
    if not (Int64.equal bar_ts_parsed 0L) then
      match
        try Some (Instrument.of_qualified cmd.instrument)
        with Invalid_argument _ -> None
      with
      | Some i -> Hashtbl.replace last_seen_bar_ts i bar_ts_parsed
      | None -> ()
  in
  let dispatch_cancel_pending_order
      (cmd : Paper_broker_commands.Cancel_pending_order_command.t) =
    match
      Paper_broker_commands.Cancel_pending_order_command_workflow.execute
        ~store:store_module ~store_handle:store ~command_log:command_log_module
        ~command_log_handle:command_log ~now_ts ~publish_order_cancelled cmd
    with
    | Ok () -> ()
    | Error _ ->
        (* Cancel-not-found / already-terminal: idempotent compensation;
           silently dropped. *)
        ()
  in
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.submit-order-command" ~group:"paper-broker"
         ~t_of_yojson:Paper_broker_commands.Submit_order_command.t_of_yojson)
      dispatch_submit_order
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.cancel-order-command" ~group:"paper-broker"
         ~t_of_yojson:Paper_broker_commands.Cancel_pending_order_command.t_of_yojson)
      dispatch_cancel_pending_order
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.bar-updated" ~group:"paper-broker"
         ~t_of_yojson:
           Paper_broker_external_integration_events.Bar_updated_integration_event
           .t_of_yojson)
      (Paper_broker_external_integration_events.Bar_updated_integration_event_handler
       .handle ~dispatch_apply_bar)
  in
  let http_handler : Inbound_http.Route.handler = fun _request _body -> None in
  { http_handler }

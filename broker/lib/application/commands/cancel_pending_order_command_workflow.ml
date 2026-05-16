module Order_cancelled = Broker_integration_events.Order_cancelled_integration_event
module type Command_log = Broker_store.Order_command_log.S

let publish_cancelled
    ~(publish_order_cancelled : Order_cancelled.t -> unit)
    ~(cmd : Cancel_pending_order_command.t)
    ~(cancelled_ts : int64) : unit =
  publish_order_cancelled
    Order_cancelled.
      {
        correlation_id = cmd.correlation_id;
        placement_id = cmd.placement_id;
        cancelled_ts = Datetime.Iso8601.format cancelled_ts;
      }

let execute
    (type log)
    ~(broker : Broker.client)
    ~(command_log : (module Command_log with type t = log))
    ~(command_log_handle : log)
    ~(now_ts : unit -> int64)
    ~(publish_order_cancelled : Order_cancelled.t -> unit)
    (cmd : Cancel_pending_order_command.t) :
    (unit, Cancel_pending_order_command_handler.handle_error) Rop.t =
  let module L = (val command_log : Command_log with type t = log) in
  match Cancel_pending_order_command_handler.handle ~broker ~now_ts cmd with
  | Ok (Cancel_confirmed { cancelled_ts }) | Ok (Cancel_pending { cancelled_ts }) ->
      L.record_cancel command_log_handle ~placement_id:cmd.placement_id
        ~correlation_id:cmd.correlation_id;
      publish_cancelled ~publish_order_cancelled ~cmd ~cancelled_ts;
      Rop.succeed ()
  | Ok (Cancel_refused _) | Ok (Unreachable _) ->
      (* Terminal-on-venue (already filled / expired / rejected)
         and transport failures don't emit an IE today. In the
         terminal case the originating Submit's downstream IEs
         (future Order_filled / current Order_rejected /
         Order_unreachable) drive the saga's compensation; a
         dedicated [Order_uncancellable] IE for the unreachable
         path is a follow-up once Account grows compensation
         semantics for stuck cancels. *)
      Rop.succeed ()
  | Error errs -> Error errs

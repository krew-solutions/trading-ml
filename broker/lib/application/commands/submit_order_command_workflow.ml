module Order_accepted = Broker_integration_events.Order_accepted_integration_event
module Order_rejected = Broker_integration_events.Order_rejected_integration_event
module Order_unreachable = Broker_integration_events.Order_unreachable_integration_event

let execute
    ~(broker : Broker.client)
    ~(publish_accepted : Order_accepted.t -> unit)
    ~(publish_rejected : Order_rejected.t -> unit)
    ~(publish_unreachable : Order_unreachable.t -> unit)
    (cmd : Submit_order_command.t) :
    (unit, Submit_order_command_handler.handle_error) Rop.t =
  let cid = cmd.correlation_id in
  let pid = cmd.placement_id in
  match Submit_order_command_handler.handle ~broker cmd with
  | Ok (Accepted order) ->
      publish_accepted
        Order_accepted.
          {
            correlation_id = cid;
            placement_id = pid;
            broker_order = Order_view_model.of_domain order;
          };
      Rop.succeed ()
  | Ok (Rejected { order = _; reason }) ->
      publish_rejected
        Order_rejected.{ correlation_id = cid; placement_id = pid; reason };
      Rop.succeed ()
  | Ok (Unreachable { reason }) ->
      publish_unreachable
        Order_unreachable.{ correlation_id = cid; placement_id = pid; reason };
      Rop.succeed ()
  | Error errs ->
      (* Preserve historical behaviour: validation failures surface as
         Order_unreachable (wire-malformed inputs never reach the
         broker, but the saga treats the absent submission the same
         way — release the reservation). *)
      let reasons =
        List.map
          (function
            | Submit_order_command_handler.Validation v ->
                Submit_order_command_handler.validation_error_to_string v)
          errs
      in
      let reason = String.concat "; " reasons in
      publish_unreachable
        Order_unreachable.{ correlation_id = cid; placement_id = pid; reason };
      Error errs

(** Command pipeline for {!Submit_order_command.t}.

    Composes {!Submit_order_command_handler.handle} with the
    integration-event publishing side effects. Outcomes flow
    exclusively through the three port callbacks:

    - {b Accepted}: broker returned a non-[Rejected] order →
      [publish_accepted].
    - {b Rejected}: broker returned [status = Rejected] →
      [publish_rejected].
    - {b Unreachable}: broker adapter raised (transport, wire
      decode, anything else) → [publish_unreachable].
    - {b Validation failure}: command's wire primitives failed
      to parse → [publish_unreachable] with the concatenated
      reasons (the saga treats a never-submitted order the same
      way as an unreachable broker — release the reservation).

    {b Invariant.} Exactly one of the three ports fires per call.
    Account's compensation handler on {!Order_rejected} /
    {!Order_unreachable} relies on this for correct rollback.

    The workflow is bus-agnostic: it depends on plain
    [_ -> unit] ports, not on any specific transport. The
    composition root binds these ports to whichever bus
    implementation is in use.

    The [Rop.t] return surfaces the validation error list to
    callers that want to log it (the bus subscriber today
    discards it — the IE has already been published). *)

module Order_accepted :
    module type of Broker_integration_events.Order_accepted_integration_event

module Order_rejected :
    module type of Broker_integration_events.Order_rejected_integration_event

module Order_unreachable :
    module type of Broker_integration_events.Order_unreachable_integration_event

val execute :
  broker:Broker.client ->
  publish_accepted:(Order_accepted.t -> unit) ->
  publish_rejected:(Order_rejected.t -> unit) ->
  publish_unreachable:(Order_unreachable.t -> unit) ->
  Submit_order_command.t ->
  (unit, Submit_order_command_handler.handle_error) Rop.t

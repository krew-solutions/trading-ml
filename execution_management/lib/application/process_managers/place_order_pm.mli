(** Place_order Process Manager.

    Coordinates the cross-BC saga that turns a [Trade_intent_approved]
    integration event into a fully-placed broker order:

    {v
      Trade_intent_approved   →  Reserve_command  (Account)
              ↓                          ↓
              ⤷ Awaiting_reservation     ⤷ Amount_reserved          → Submit_order_command (Broker)
                                              ↓                                ↓
                                              ⤷ Submitted                       ⤷ Order_accepted   → Done
                                                                                ⤷ Order_rejected   → Release_command + Compensated
                                                                                ⤷ Order_unreachable → Release_command + Compensated
                                         ⤷ Reservation_rejected     → Compensated
    v}

    Built on top of {!Workflow_engine}: the {!Definition} module is a
    pure state machine, the {!Engine} module wraps it with a
    persistent store and a [dispatch] callback that bridges the
    saga's [command] union onto the workflow_engine's command bus.

    State is keyed by the saga-instance [correlation_id], minted by
    the saga initiator (today PM's reconciler in
    {!Trade_intents_planned_integration_event.leg.correlation_id})
    and echoed verbatim by every downstream BC. *)

type payload = {
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  kind_type : string;
  kind_price : string option;
  kind_stop_price : string option;
  kind_limit_price : string option;
  tif : string;
}
(** Trade payload captured at saga start; threaded through the state
    so the [Submit] hop has all the venue-side parameters it needs
    once the reservation lands. The defaults for [kind] / [tif] are
    chosen by the saga at start time — the upstream
    Trade_intent_approved IE does not carry venue-routing metadata
    today (rationale: alpha/PM/Pre_trade_risk operate on direction
    + quantity, not order shape). *)

type state =
  | Awaiting_reservation of { payload : payload }
  | Submitted of { payload : payload; reservation_id : int }
  | Done of { reservation_id : int }
  | Compensated of { reason : string }

type event =
  | Amount_reserved of
      Execution_management_external_integration_events.Amount_reserved_integration_event.t
  | Reservation_rejected of
      Execution_management_external_integration_events
      .Reservation_rejected_integration_event
      .t
  | Order_accepted of
      Execution_management_external_integration_events.Order_accepted_integration_event.t
  | Order_rejected of
      Execution_management_external_integration_events.Order_rejected_integration_event.t
  | Order_unreachable of
      Execution_management_external_integration_events.Order_unreachable_integration_event
      .t

(** Saga-local command union. The factory's [dispatch] closure
    serialises each variant onto the appropriate bus topic — Account
    for Reserve / Release, Broker for Submit. The DTO field shapes
    match the Account / Broker command DTOs verbatim; we keep them
    saga-local to avoid importing those BCs' command libraries. *)
type command =
  | Dispatch_reserve of {
      correlation_id : string;
      side : string;
      symbol : string;
      quantity : string;
      price : string;
    }
  | Dispatch_submit of {
      correlation_id : string;
      reservation_id : int;
      symbol : string;
      side : string;
      quantity : string;
      kind_type : string;
      kind_price : string option;
      kind_stop_price : string option;
      kind_limit_price : string option;
      tif : string;
    }
  | Dispatch_release of { correlation_id : string; reservation_id : int }

module Definition :
  Workflow_engine.WORKFLOW
    with type state = state
     and type event = event
     and type command = command

module Engine :
    module type of Workflow_engine.Make (Definition) (Workflow_engine.In_memory_store)

val initial_payload :
  book_id:string -> symbol:string -> side:string -> quantity:string -> payload
(** Build the initial saga state from an inbound trade-approved
    payload. The defaults for [kind_type] / [tif] are
    ["MARKET"] and ["DAY"]. *)

val reserve_for_start :
  correlation_id:string -> payload:payload -> price:string -> command
(** Compute the [Reserve] command that is dispatched alongside
    [Engine.start]. Saga-internal contract — the [transition] does
    not see this command because [start] is not a runtime event in
    the workflow_engine API. *)

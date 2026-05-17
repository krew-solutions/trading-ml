(** In-process test harness for the Execution_management BC's
    Open_order_ticket saga.

    Boots the saga {!Engine} on top of an {!In_memory_store} and
    a recording [dispatch] callback: every saga-emitted command
    is appended to a list the Then-steps inspect. Tests for the
    broker-leg lifecycle live in [order_ticket_test.ml] and the
    BDD scenarios — the harness here covers only the saga's
    own responsibility (Reserve hand-off, Amount_reserved → Done,
    Reservation_rejected → Compensated). *)

module Pm = Execution_management_process_managers.Order_process_manager
module Inbound = Execution_management_external_integration_events
module Iqr = Execution_management_external_view_models

type ctx = { engine : Pm.Engine.t; dispatched : Pm.command list ref }

let fresh_ctx () =
  let store = Workflow_engine.In_memory_store.create () in
  let dispatched = ref [] in
  let dispatch cmd = dispatched := cmd :: !dispatched in
  let engine = Pm.Engine.create ~store ~dispatch in
  { engine; dispatched }

let start_saga ?directive ctx ~correlation_id ~book_id ~symbol ~side ~quantity
    ~price =
  let payload =
    Pm.initial_payload ?directive ~book_id ~symbol ~side ~quantity ()
  in
  Pm.Engine.start ctx.engine ~correlation_id (Pm.Awaiting_reservation { payload });
  let dispatch_cb cmd = ctx.dispatched := cmd :: !(ctx.dispatched) in
  dispatch_cb (Pm.reserve_for_start ~correlation_id ~payload ~price);
  ctx

let instrument_vm ~symbol : Iqr.Instrument_view_model.t =
  match String.split_on_char '@' symbol with
  | [ ticker; venue ] -> { ticker; venue; isin = None; board = None }
  | _ -> { ticker = symbol; venue = ""; isin = None; board = None }

let push_amount_reserved
    ctx
    ~correlation_id
    ~reservation_id
    ~symbol
    ~side
    ~quantity
    ~price
    ~reserved_cash =
  let ev : Inbound.Amount_reserved_integration_event.t =
    {
      correlation_id;
      reservation_id;
      side;
      instrument = instrument_vm ~symbol;
      quantity;
      price;
      reserved_cash;
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Amount_reserved ev);
  ctx

let push_reservation_rejected ctx ~correlation_id ~symbol ~side ~quantity ~reason =
  let ev : Inbound.Reservation_rejected_integration_event.t =
    { correlation_id; side; instrument = instrument_vm ~symbol; quantity; reason }
  in
  Pm.Engine.on_event ctx.engine (Pm.Reservation_rejected ev);
  ctx

let saga_state ctx ~correlation_id = Pm.Engine.get ctx.engine ~correlation_id
let active_count ctx = Pm.Engine.active_count ctx.engine
let dispatched_commands ctx = List.rev !(ctx.dispatched)

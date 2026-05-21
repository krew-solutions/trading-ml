(** In-process test harness for the Order_management BC's
    saga. Drives the {!Engine} with synthetic IEs and records
    dispatched commands for the Then-steps. *)

module Pm = Order_management_process_managers.Order_process_manager
module Inbound = Order_management_external_integration_events
module Iqr = Order_management_external_view_models

type ctx = { engine : Pm.Engine.t; dispatched : Pm.command list ref }

let fresh_ctx () =
  let store = Workflow_engine.In_memory_store.create () in
  let dispatched = ref [] in
  let dispatch cmd = dispatched := cmd :: !dispatched in
  let engine = Pm.Engine.create ~store ~dispatch in
  { engine; dispatched }

let start_saga ?directive ctx ~correlation_id ~book_id ~symbol ~side ~quantity ~price =
  let payload = Pm.initial_payload ?directive ~book_id ~symbol ~side ~quantity () in
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

let progress_vm ~total_quantity ~cumulative_filled ~remaining_quantity ~total_fees :
    Iqr.Progress_view_model.t =
  { total_quantity; cumulative_filled; remaining_quantity; total_fees }

let push_ticket_fill_recorded
    ctx
    ~correlation_id
    ~ticket_id
    ~reservation_id
    ~quantity
    ~price
    ~fee =
  let ev : Inbound.Order_ticket_fill_recorded_integration_event.t =
    {
      correlation_id;
      ticket_id;
      reservation_id;
      fill_quantity = quantity;
      fill_price = price;
      fee;
      occurred_at = "1970-01-01T00:00:00Z";
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Ticket_fill_recorded ev);
  ctx

let push_ticket_completed ctx ~correlation_id ~ticket_id ~reservation_id =
  let ev : Inbound.Order_ticket_completed_integration_event.t =
    {
      correlation_id;
      ticket_id;
      reservation_id;
      progress =
        progress_vm ~total_quantity:"10" ~cumulative_filled:"10" ~remaining_quantity:"0"
          ~total_fees:"0";
      occurred_at = "1970-01-01T00:00:00Z";
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Ticket_completed ev);
  ctx

let push_ticket_cancelled ctx ~correlation_id ~ticket_id ~reservation_id ~reason =
  let ev : Inbound.Order_ticket_cancelled_integration_event.t =
    {
      correlation_id;
      ticket_id;
      reservation_id;
      reason;
      progress =
        progress_vm ~total_quantity:"10" ~cumulative_filled:"0" ~remaining_quantity:"10"
          ~total_fees:"0";
      occurred_at = "1970-01-01T00:00:00Z";
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Ticket_cancelled ev);
  ctx

let push_ticket_failed ctx ~correlation_id ~ticket_id ~reservation_id ~reason =
  let ev : Inbound.Order_ticket_failed_integration_event.t =
    {
      correlation_id;
      ticket_id;
      reservation_id;
      reason;
      progress =
        progress_vm ~total_quantity:"10" ~cumulative_filled:"0" ~remaining_quantity:"10"
          ~total_fees:"0";
      occurred_at = "1970-01-01T00:00:00Z";
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Ticket_failed ev);
  ctx

let saga_state ctx ~correlation_id = Pm.Engine.get ctx.engine ~correlation_id
let active_count ctx = Pm.Engine.active_count ctx.engine
let dispatched_commands ctx = List.rev !(ctx.dispatched)

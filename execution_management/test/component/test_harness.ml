(** In-process test harness for the Execution_management BC's
    Place_order Process Manager.

    Boots the saga {!Engine} on top of an {!In_memory_store} and a
    recording [dispatch] callback: every saga-emitted command is
    appended to a list the Then-steps inspect. The harness mirrors
    the production factory's setup with two simplifications: the
    bus is replaced by direct {!Engine.on_event} calls (the
    factory's role is to translate inbound bus messages into the
    saga's [event] union, not to add behaviour), and the
    kill-switch / rate-limit gate that lives between
    [Trade_intent_approved] arrival and [Engine.start] is bypassed
    — saga-internal transitions are the test subject here, not the
    factory's gating policy.

    The harness exposes one [start_saga] helper that mirrors the
    factory's start sequence: [Engine.start] for the saga state,
    plus a synchronous [Reserve] dispatch via {!reserve_for_start}.
    Every later transition is driven by [push_*] helpers that wrap
    {!Engine.on_event} on the appropriate event constructor. *)

module Pm = Execution_management_process_managers.Place_order_pm
module Inbound = Execution_management_external_integration_events
module Iqr = Execution_management_external_view_models

type ctx = { engine : Pm.Engine.t; dispatched : Pm.command list ref }

let fresh_ctx () =
  let store = Workflow_engine.In_memory_store.create () in
  let dispatched = ref [] in
  let dispatch cmd = dispatched := cmd :: !dispatched in
  let engine = Pm.Engine.create ~store ~dispatch in
  { engine; dispatched }

(** Mirror the factory's saga-start sequence: register the saga
    instance and synchronously dispatch its first [Reserve] command.
    Defaults match the inbound-IE shape — symbol, side and quantity
    are the only fields the upstream Trade_intent_approved IE
    carries. The price is a stand-in supplied by the harness; in
    production the factory passes [ev.quantity] today (see the
    in-line comment in [factory.ml]) — that placeholder is
    orthogonal to saga semantics. *)
let start_saga ctx ~correlation_id ~book_id ~symbol ~side ~quantity ~price =
  let payload = Pm.initial_payload ~book_id ~symbol ~side ~quantity in
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

let order_view ~symbol ~side ~quantity : Iqr.Order_view_model.t =
  {
    id = "broker-order";
    exec_id = "exec-id";
    client_order_id = "client-id";
    instrument = instrument_vm ~symbol;
    side;
    quantity;
    filled = "0";
    remaining = quantity;
    kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
    tif = "DAY";
    status = "NEW";
    created_ts = 0L;
  }

let push_order_accepted ctx ~correlation_id ~reservation_id ~symbol ~side ~quantity =
  let ev : Inbound.Order_accepted_integration_event.t =
    {
      correlation_id;
      placement_id = reservation_id;
      broker_order = order_view ~symbol ~side ~quantity;
    }
  in
  Pm.Engine.on_event ctx.engine (Pm.Order_accepted ev);
  ctx

let push_order_rejected ctx ~correlation_id ~reservation_id ~reason =
  let ev : Inbound.Order_rejected_integration_event.t =
    { correlation_id; placement_id = reservation_id; reason }
  in
  Pm.Engine.on_event ctx.engine (Pm.Order_rejected ev);
  ctx

let push_order_unreachable ctx ~correlation_id ~reservation_id ~reason =
  let ev : Inbound.Order_unreachable_integration_event.t =
    { correlation_id; placement_id = reservation_id; reason }
  in
  Pm.Engine.on_event ctx.engine (Pm.Order_unreachable ev);
  ctx

(** Saga snapshot helpers — the Then-steps assert against these
    rather than against private state. *)
let saga_state ctx ~correlation_id = Pm.Engine.get ctx.engine ~correlation_id

let active_count ctx = Pm.Engine.active_count ctx.engine

let dispatched_commands ctx = List.rev !(ctx.dispatched)

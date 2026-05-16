module Inbound = Execution_management_external_integration_events

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

type state =
  | Awaiting_reservation of { payload : payload }
  | Done of { reservation_id : int }
  | Compensated of { reason : string }

type event =
  | Amount_reserved of Inbound.Amount_reserved_integration_event.t
  | Reservation_rejected of Inbound.Reservation_rejected_integration_event.t

type command =
  | Dispatch_reserve of {
      correlation_id : string;
      side : string;
      symbol : string;
      quantity : string;
      price : string;
    }

let initial_payload ~book_id ~symbol ~side ~quantity =
  {
    book_id;
    symbol;
    side;
    quantity;
    kind_type = "MARKET";
    kind_price = None;
    kind_stop_price = None;
    kind_limit_price = None;
    tif = "DAY";
  }

let reserve_for_start ~correlation_id ~(payload : payload) ~price =
  Dispatch_reserve
    {
      correlation_id;
      side = payload.side;
      symbol = payload.symbol;
      quantity = payload.quantity;
      price;
    }

module Definition = struct
  type nonrec state = state
  type nonrec event = event
  type nonrec command = command

  let name = "open_order_ticket"

  let correlation_of_event = function
    | Amount_reserved e -> e.correlation_id
    | Reservation_rejected e -> e.correlation_id

  let transition (s : state) (e : event) : state * command list =
    match (s, e) with
    | Awaiting_reservation _, Amount_reserved ev ->
        (Done { reservation_id = ev.reservation_id }, [])
    | Awaiting_reservation _, Reservation_rejected ev ->
        (Compensated { reason = "rejected_by_account: " ^ ev.reason }, [])
    (* Late / duplicate events for already-terminated states: silently
       absorbed (idempotent fall-through). *)
    | _, _ -> (s, [])

  let is_terminal = function
    | Done _ | Compensated _ -> true
    | Awaiting_reservation _ -> false
end

module Engine = Workflow_engine.Make (Definition) (Workflow_engine.In_memory_store)

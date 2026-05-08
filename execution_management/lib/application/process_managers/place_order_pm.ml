module Inbound = Execution_management_inbound_integration_events

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
  | Submitted of { payload : payload; reservation_id : int }
  | Done of { reservation_id : int }
  | Compensated of { reason : string }

type event =
  | Amount_reserved of Inbound.Amount_reserved_integration_event.t
  | Reservation_rejected of Inbound.Reservation_rejected_integration_event.t
  | Order_accepted of Inbound.Order_accepted_integration_event.t
  | Order_rejected of Inbound.Order_rejected_integration_event.t
  | Order_unreachable of Inbound.Order_unreachable_integration_event.t

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

let qualify (i : Inbound.Amount_reserved_integration_event.t) : string =
  let inst = i.instrument in
  let base = Printf.sprintf "%s@%s" inst.ticker inst.venue in
  match inst.board with
  | Some b -> base ^ "/" ^ b
  | None -> base

module Definition = struct
  type nonrec state = state
  type nonrec event = event
  type nonrec command = command

  let name = "place_order"

  let correlation_of_event = function
    | Amount_reserved e -> e.correlation_id
    | Reservation_rejected e -> e.correlation_id
    | Order_accepted e -> e.correlation_id
    | Order_rejected e -> e.correlation_id
    | Order_unreachable e -> e.correlation_id

  let transition (s : state) (e : event) : state * command list =
    match (s, e) with
    | Awaiting_reservation { payload }, Amount_reserved ev ->
        let symbol = qualify ev in
        let cmd =
          Dispatch_submit
            {
              correlation_id = ev.correlation_id;
              reservation_id = ev.reservation_id;
              symbol;
              side = payload.side;
              quantity = payload.quantity;
              kind_type = payload.kind_type;
              kind_price = payload.kind_price;
              kind_stop_price = payload.kind_stop_price;
              kind_limit_price = payload.kind_limit_price;
              tif = payload.tif;
            }
        in
        (Submitted { payload; reservation_id = ev.reservation_id }, [ cmd ])
    | Awaiting_reservation _, Reservation_rejected ev ->
        (Compensated { reason = "rejected_by_account: " ^ ev.reason }, [])
    | Submitted { reservation_id; _ }, Order_accepted _ -> (Done { reservation_id }, [])
    | Submitted { reservation_id; _ }, Order_rejected ev ->
        ( Compensated { reason = "rejected_by_broker: " ^ ev.reason },
          [ Dispatch_release { correlation_id = ev.correlation_id; reservation_id } ] )
    | Submitted { reservation_id; _ }, Order_unreachable ev ->
        ( Compensated { reason = "broker_unreachable: " ^ ev.reason },
          [ Dispatch_release { correlation_id = ev.correlation_id; reservation_id } ] )
    (* Late / duplicate events for already-progressed states: silently
       absorbed (idempotent fall-through). *)
    | _, _ -> (s, [])

  let is_terminal = function
    | Done _ | Compensated _ -> true
    | Awaiting_reservation _ | Submitted _ -> false
end

module Engine = Workflow_engine.Make (Definition) (Workflow_engine.In_memory_store)

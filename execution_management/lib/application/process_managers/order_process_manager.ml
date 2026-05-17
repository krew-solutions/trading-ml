module Inbound = Execution_management_external_integration_events

type directive_payload = {
  directive_kind : string;
  directive_params : string option;
}

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
  directive : directive_payload option;
      (** Wire-shape execution directive captured at saga start
          (kind tag + optional per-strategy JSON params blob).
          [None] when the originating trader intent omitted it;
          the EMS-side command handler then falls back to the
          internal Execution_policy default. *)
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
  | Dispatch_open_ticket of {
      reservation_id : int;
      correlation_id : string;
      book_id : string;
      symbol : string;
      side : string;
      quantity : string;
      directive : directive_payload option;
    }

let initial_payload ?directive ~book_id ~symbol ~side ~quantity () =
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
    directive;
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

  let name = "order_process_manager"

  let correlation_of_event = function
    | Amount_reserved e -> e.correlation_id
    | Reservation_rejected e -> e.correlation_id

  let transition (s : state) (e : event) : state * command list =
    match (s, e) with
    | Awaiting_reservation { payload }, Amount_reserved ev ->
        let open_cmd =
          Dispatch_open_ticket
            {
              reservation_id = ev.reservation_id;
              correlation_id = ev.correlation_id;
              book_id = payload.book_id;
              symbol = payload.symbol;
              side = payload.side;
              quantity = payload.quantity;
              directive = payload.directive;
            }
        in
        (Done { reservation_id = ev.reservation_id }, [ open_cmd ])
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

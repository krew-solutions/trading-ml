module Pm = Order_management_process_managers.Order_process_manager
module Inbound = Order_management_external_integration_events

type t = { http_handler : Inbound_http.Route.handler }

(** Wire-format DTOs for cross-BC commands OM dispatches. Kept
    factory-local to avoid importing the receiving BCs' command
    libraries (per ADR-0001's BC-independence rule); each wire
    shape is fixed by the consumer-side .atd. *)

type wire_reserve = {
  correlation_id : string;
  side : string;
  symbol : string;
  quantity : string;
  price : string;
}
[@@deriving yojson]

type wire_release = { correlation_id : string; reservation_id : int } [@@deriving yojson]

type wire_commit_fill = {
  correlation_id : string;
  reservation_id : int;
  quantity : string;
  price : string;
  fee : string;
}
[@@deriving yojson]

type wire_directive = { kind : string; params : string option } [@@deriving yojson]

type wire_open_order_ticket = {
  reservation_id : int;
  correlation_id : string;
  book_id : string;
  symbol : string;
  side : string;
  quantity : string;
  execution_directive : wire_directive option;
}
[@@deriving yojson]

let qualify_instrument (i : Inbound.Trade_intent_approved_integration_event.t) : string =
  i.symbol

let build ~bus : t =
  let mu = Mutex.create () in
  let with_lock f =
    Mutex.lock mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock mu) f
  in

  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_reserve =
    produce ~uri:"in-memory://account.reserve-command" ~yojson_of:yojson_of_wire_reserve
  in
  let publish_release =
    produce ~uri:"in-memory://account.release-command" ~yojson_of:yojson_of_wire_release
  in
  let publish_commit_fill =
    produce ~uri:"in-memory://account.commit-fill-command"
      ~yojson_of:yojson_of_wire_commit_fill
  in
  let publish_open_order_ticket =
    produce ~uri:"in-memory://execution-management.open-order-ticket-command"
      ~yojson_of:yojson_of_wire_open_order_ticket
  in

  (* Saga command dispatcher. All four variants leave the BC over
     the bus (cross-BC commands per ADR 0020). *)
  let dispatch (cmd : Pm.command) : unit =
    match cmd with
    | Dispatch_reserve { correlation_id; side; symbol; quantity; price } ->
        publish_reserve { correlation_id; side; symbol; quantity; price }
    | Dispatch_open_ticket
        { reservation_id; correlation_id; book_id; symbol; side; quantity; directive } ->
        let execution_directive =
          Option.map
            (fun (d : Pm.directive_payload) : wire_directive ->
              { kind = d.directive_kind; params = d.directive_params })
            directive
        in
        publish_open_order_ticket
          {
            reservation_id;
            correlation_id;
            book_id;
            symbol;
            side;
            quantity;
            execution_directive;
          }
    | Dispatch_commit_fill { correlation_id; reservation_id; quantity; price; fee } ->
        publish_commit_fill { correlation_id; reservation_id; quantity; price; fee }
    | Dispatch_release { correlation_id; reservation_id } ->
        publish_release { correlation_id; reservation_id }
  in
  let saga_store = Workflow_engine.In_memory_store.create () in
  let engine = Pm.Engine.create ~store:saga_store ~dispatch in
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://pre-trade-risk.trade-intent-approved"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Trade_intent_approved_integration_event.t_of_yojson)
      (fun (ev : Inbound.Trade_intent_approved_integration_event.t) ->
        with_lock (fun () ->
            let directive =
              Option.map
                (fun (d :
                       Order_management_external_view_models
                       .Execution_directive_view_model
                       .t) : Pm.directive_payload ->
                  { directive_kind = d.kind; directive_params = d.params })
                ev.execution_directive
            in
            let payload =
              Pm.initial_payload ?directive ~book_id:ev.book_id
                ~symbol:(qualify_instrument ev) ~side:ev.side ~quantity:ev.quantity ()
            in
            Pm.Engine.start engine ~correlation_id:ev.correlation_id
              (Pm.Awaiting_reservation { payload });
            dispatch
              (Pm.reserve_for_start ~correlation_id:ev.correlation_id ~payload
                 ~price:ev.quantity)))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.amount-reserved" ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Amount_reserved_integration_event.t_of_yojson) (fun ev ->
        Pm.Engine.on_event engine (Pm.Amount_reserved ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-rejected"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Reservation_rejected_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Reservation_rejected ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://execution-management.order-ticket-fill-recorded"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Order_ticket_fill_recorded_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Ticket_fill_recorded ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://execution-management.order-ticket-completed"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Order_ticket_completed_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Ticket_completed ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://execution-management.order-ticket-cancelled"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Order_ticket_cancelled_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Ticket_cancelled ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://execution-management.order-ticket-failed"
         ~group:"order-management-saga"
         ~t_of_yojson:Inbound.Order_ticket_failed_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Ticket_failed ev))
  in
  let http_handler : Inbound_http.Route.handler = fun _request _body -> None in
  { http_handler }

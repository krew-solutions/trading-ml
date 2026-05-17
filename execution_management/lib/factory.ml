module Pm = Execution_management_process_managers.Order_process_manager
module Inbound = Execution_management_external_integration_events
module Outbound_ie = Execution_management_integration_events
module Cmds = Execution_management_commands
module Ports = Execution_management_ports
module Persistence = Execution_management_persistence
module View_models = Execution_management_view_models
module Queries = Execution_management_queries
module Ot = Execution_management.Order_ticket

type t = { http_handler : Inbound_http.Route.handler }

type config = {
  initial_equity : Decimal.t;
  max_drawdown_pct : float;
  rate_limit : (int * float) option;
}

(** Wire-format DTOs for cross-BC commands EMS dispatches over the
    bus. Kept saga-local to avoid importing the receiving BCs'
    command libraries (per ADR-0001's BC-independence rule); the
    wire shape is fixed by the consumer-side schema. *)

type wire_reserve = {
  correlation_id : string;
  side : string;
  symbol : string;
  quantity : string;
  price : string;
}
[@@deriving yojson]

type wire_release = { correlation_id : string; reservation_id : int }
[@@deriving yojson]

type wire_order_kind = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]

type wire_submit = {
  correlation_id : string;
  placement_id : int;
  symbol : string;
  side : string;
  quantity : string;
  kind : wire_order_kind;
  tif : string;
}
[@@deriving yojson]

type wire_cancel = { correlation_id : string; placement_id : int }
[@@deriving yojson]

(** Wire-format placement_id encoding: the OrderTicket aggregate
    mints local sequence ids (1, 2, 3, ...) per ticket; the
    factory translates to a globally-unique wire id for broker
    correlation. The encoding is reversible so inbound broker IEs
    can be decoded back to (ticket_id, local_id) at the ACL
    boundary. *)
let placement_id_seq_capacity = 1_000_000

let encode_wire_placement_id ~ticket_id ~local_seq =
  (ticket_id * placement_id_seq_capacity) + local_seq

let decode_wire_to_ticket_id wire_pid = wire_pid / placement_id_seq_capacity

let qualify_instrument (i : Inbound.Trade_intent_approved_integration_event.t) :
    string =
  i.symbol

let to_wire_kind (k : Ot.Placement.Values.Order_kind.t) : wire_order_kind =
  match k with
  | Market ->
      { type_ = "MARKET"; price = None; stop_price = None; limit_price = None }
  | Limit { price } ->
      { type_ = "LIMIT"; price = Some (Decimal.to_string price);
        stop_price = None; limit_price = None }
  | Stop { stop_price } ->
      { type_ = "STOP"; price = None;
        stop_price = Some (Decimal.to_string stop_price); limit_price = None }
  | Stop_limit { stop_price; limit_price } ->
      { type_ = "STOP_LIMIT"; price = None;
        stop_price = Some (Decimal.to_string stop_price);
        limit_price = Some (Decimal.to_string limit_price) }

let to_wire_tif (t : Ot.Placement.Values.Tif.t) : string =
  match t with Gtc -> "GTC" | Day -> "DAY" | Ioc -> "IOC" | Fok -> "FOK"

let build ~bus ~now ~(config : config) : t =
  let mu = Mutex.create () in
  let kill_switch =
    ref
      (Execution_management.Kill_switch.make ~initial_equity:config.initial_equity
         ~max_drawdown_pct:
           (Execution_management.Kill_switch.Values.Max_drawdown_pct.of_float
              config.max_drawdown_pct))
  in
  let rate_limit =
    ref
      (match config.rate_limit with
      | Some (max_orders, window_seconds) ->
          Some
            (Execution_management.Rate_limit.make
               ~config:
                 (Execution_management.Rate_limit.Values.Rate_limit_config.make
                    ~max_orders ~window_seconds))
      | None -> None)
  in
  let with_lock f =
    Mutex.lock mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock mu) f
  in
  let now_iso8601 () = Datetime.Iso8601.format (now ()) in

  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in

  let publish_blocked =
    produce ~uri:"in-memory://execution-management.trade-submission-blocked"
      ~yojson_of:Outbound_ie.Trade_submission_blocked_integration_event.yojson_of_t
  in
  let publish_kill_switch_tripped =
    produce ~uri:"in-memory://execution-management.kill-switch-tripped"
      ~yojson_of:Outbound_ie.Kill_switch_tripped_integration_event.yojson_of_t
  in
  let publish_ticket_opened =
    produce ~uri:"in-memory://execution-management.order-ticket-opened"
      ~yojson_of:Outbound_ie.Order_ticket_opened_integration_event.yojson_of_t
  in
  let publish_ticket_completed =
    produce ~uri:"in-memory://execution-management.order-ticket-completed"
      ~yojson_of:Outbound_ie.Order_ticket_completed_integration_event.yojson_of_t
  in
  let publish_ticket_cancelled =
    produce ~uri:"in-memory://execution-management.order-ticket-cancelled"
      ~yojson_of:Outbound_ie.Order_ticket_cancelled_integration_event.yojson_of_t
  in
  let publish_ticket_failed =
    produce ~uri:"in-memory://execution-management.order-ticket-failed"
      ~yojson_of:Outbound_ie.Order_ticket_failed_integration_event.yojson_of_t
  in
  let publish_reserve =
    produce ~uri:"in-memory://account.reserve-command" ~yojson_of:yojson_of_wire_reserve
  in
  let publish_release =
    produce ~uri:"in-memory://account.release-command" ~yojson_of:yojson_of_wire_release
  in
  let publish_submit =
    produce ~uri:"in-memory://broker.submit-order-command"
      ~yojson_of:yojson_of_wire_submit
  in
  let publish_cancel =
    produce ~uri:"in-memory://broker.cancel-pending-order-command"
      ~yojson_of:yojson_of_wire_cancel
  in

  (* OrderTicket persistence + per-ticket correlation_id store.
     The aggregate is pure; the factory threads the saga-minted
     correlation_id through the outbound broker dispatches via a
     side table keyed on ticket_id. The correlation_id is set on
     Dispatch_open_ticket and read on every subsequent
     Placement_dispatched / Ticket_cancelling_started event. *)
  let ticket_store = Persistence.In_memory_ticket_store.create () in
  let ticket_store_module
      : (module Ports.Ticket_store.S with type t = Persistence.In_memory_ticket_store.t)
      =
    (module Persistence.In_memory_ticket_store)
  in
  let correlation_by_ticket : (int, string) Hashtbl.t = Hashtbl.create 64 in
  let ticket_intent : (int, Ot.Values.Trade_intent.t) Hashtbl.t =
    Hashtbl.create 64
  in

  (* Aggregate event → outbound side-effect dispatcher. Called by
     every command_workflow after the aggregate produces events.
     Pattern-matches exhaustively (closed Order_ticket.event
     variant); silent on events that have no outbound effect yet
     (Ev_ticket_opened / Ev_placement_acknowledged / etc — those
     surface as outbound IEs in PR5). *)
  let correlation_for tid =
    Option.value (Hashtbl.find_opt correlation_by_ticket tid) ~default:""
  in
  let publish_aggregate_event (ev : Ot.event) : unit =
    match ev with
    | Ev_ticket_opened e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        Hashtbl.replace ticket_intent tid e.intent;
        publish_ticket_opened
          (Outbound_ie.Order_ticket_opened_integration_event.of_domain
             ~correlation_id:(correlation_for tid) e)
    | Ev_placement_dispatched e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        let intent =
          match Hashtbl.find_opt ticket_intent tid with
          | Some i -> i
          | None -> failwith "factory: dispatched event for unknown ticket"
        in
        let wire_pid =
          encode_wire_placement_id ~ticket_id:tid
            ~local_seq:(Ot.Placement.Values.Placement_id.to_int e.placement_id)
        in
        let symbol =
          let inst = intent.instrument in
          Printf.sprintf "%s@%s"
            (Core.Ticker.to_string inst.ticker)
            (Core.Mic.to_string inst.venue)
        in
        let side = Core.Side.to_string intent.side in
        publish_submit
          {
            correlation_id;
            placement_id = wire_pid;
            symbol;
            side;
            quantity = Decimal.to_string e.quantity;
            kind = to_wire_kind e.kind;
            tif = to_wire_tif e.tif;
          }
    | Ev_ticket_cancelling_started e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        List.iter
          (fun pid ->
            let wire_pid =
              encode_wire_placement_id ~ticket_id:tid
                ~local_seq:(Ot.Placement.Values.Placement_id.to_int pid)
            in
            publish_cancel { correlation_id; placement_id = wire_pid })
          e.outstanding_placements
    | Ev_ticket_failed e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        publish_ticket_failed
          (Outbound_ie.Order_ticket_failed_integration_event.of_domain
             ~correlation_id e);
        publish_release { correlation_id; reservation_id = tid };
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid
    | Ev_ticket_cancelled e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        publish_ticket_cancelled
          (Outbound_ie.Order_ticket_cancelled_integration_event.of_domain
             ~correlation_id e);
        publish_release { correlation_id; reservation_id = tid };
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid
    | Ev_ticket_completed e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        publish_ticket_completed
          (Outbound_ie.Order_ticket_completed_integration_event.of_domain
             ~correlation_id e);
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid
    | Ev_placement_acknowledged _ | Ev_placement_filled _
    | Ev_placement_rejected _ | Ev_placement_unreachable _
    | Ev_placement_cancelled _ ->
        ()
  in

  (* Saga command dispatcher. [Dispatch_reserve] goes over the bus
     to Account; [Dispatch_open_ticket] invokes the EMS-internal
     command workflow in-process (per ADR-0017's OMS→EMS rule). *)
  let dispatch (cmd : Pm.command) : unit =
    match cmd with
    | Dispatch_reserve { correlation_id; side; symbol; quantity; price } ->
        publish_reserve { correlation_id; side; symbol; quantity; price }
    | Dispatch_open_ticket
        {
          reservation_id;
          correlation_id;
          book_id;
          symbol;
          side;
          quantity;
          directive;
        } ->
        Hashtbl.replace correlation_by_ticket reservation_id correlation_id;
        let cmd_directive =
          Option.map
            (fun (d : Pm.directive_payload) :
                 Cmds.Open_order_ticket_command.directive ->
              { kind = d.directive_kind; params = d.directive_params })
            directive
        in
        let open_cmd : Cmds.Open_order_ticket_command.t =
          {
            reservation_id;
            correlation_id;
            book_id;
            symbol;
            side;
            quantity;
            directive = cmd_directive;
          }
        in
        let _ =
          Cmds.Open_order_ticket_command_workflow.execute
            ~store:ticket_store_module ~store_handle:ticket_store
            ~publish:publish_aggregate_event ~now open_cmd
        in
        ()
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
         ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Trade_intent_approved_integration_event.t_of_yojson)
      (fun (ev : Inbound.Trade_intent_approved_integration_event.t) ->
        with_lock (fun () ->
            let halted = Execution_management.Kill_switch.is_halted !kill_switch in
            let allowed =
              if halted then false
              else
                match !rate_limit with
                | None -> true
                | Some rl -> (
                    let now_secs = Int64.to_float (now ()) in
                    match
                      Execution_management.Rate_limit.try_acquire rl ~now:now_secs
                    with
                    | `Allow rl' ->
                        rate_limit := Some rl';
                        true
                    | `Throttle -> false)
            in
            if not allowed then
              let reason = if halted then "kill_switch" else "rate_limit" in
              publish_blocked
                {
                  correlation_id = ev.correlation_id;
                  reason;
                  occurred_at = now_iso8601 ();
                }
            else
              let directive =
                Option.map
                  (fun (d :
                         Execution_management_external_view_models
                         .Execution_directive_view_model
                         .t) : Pm.directive_payload ->
                    { directive_kind = d.kind; directive_params = d.params })
                  ev.execution_directive
              in
              let payload =
                Pm.initial_payload ?directive ~book_id:ev.book_id
                  ~symbol:(qualify_instrument ev) ~side:ev.side
                  ~quantity:ev.quantity ()
              in
              Pm.Engine.start engine ~correlation_id:ev.correlation_id
                (Pm.Awaiting_reservation { payload });
              dispatch
                (Pm.reserve_for_start ~correlation_id:ev.correlation_id ~payload
                   ~price:ev.quantity)))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.amount-reserved"
         ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Amount_reserved_integration_event.t_of_yojson) (fun ev ->
        Pm.Engine.on_event engine (Pm.Amount_reserved ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-rejected"
         ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Reservation_rejected_integration_event.t_of_yojson)
      (fun ev -> Pm.Engine.on_event engine (Pm.Reservation_rejected ev))
  in

  (* Broker-IE → OrderTicket apply_* commands via ACL handlers.
     The ticket_id is derived from the wire placement_id via the
     factory's encoding convention. *)
  let ticket_id_of_placement_id wire_pid = decode_wire_to_ticket_id wire_pid in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-accepted"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_accepted_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_accepted_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-filled"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_filled_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_filled_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-rejected"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_rejected_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_rejected_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-unreachable"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_unreachable_integration_event.t_of_yojson)
      (fun ev ->
        Inbound.Order_unreachable_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-cancelled"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_cancelled_integration_event.t_of_yojson)
      (fun ev ->
        Inbound.Order_cancelled_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  (* Reservation_filled feeds the kill-switch peak / drawdown tracking. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-filled"
         ~group:"execution-management-kill-switch"
         ~t_of_yojson:Inbound.Reservation_filled_integration_event.t_of_yojson)
      (fun (ev : Inbound.Reservation_filled_integration_event.t) ->
        with_lock (fun () ->
            let equity = try Decimal.of_string ev.new_cash with _ -> Decimal.zero in
            let occurred_at = now () in
            let ks', tripped =
              Execution_management.Kill_switch.update_equity !kill_switch ~equity
                ~occurred_at
            in
            kill_switch := ks';
            match tripped with
            | None -> ()
            | Some ev_t ->
                publish_kill_switch_tripped
                  {
                    peak_equity = Decimal.to_string ev_t.peak_equity;
                    current_equity = Decimal.to_string ev_t.current_equity;
                    drawdown = ev_t.drawdown;
                    occurred_at = Datetime.Iso8601.format ev_t.occurred_at;
                  }))
  in
  let get_order_ticket ticket_id : Yojson.Safe.t option =
    let q : Queries.Get_order_ticket_query.t = { ticket_id } in
    match
      Queries.Get_order_ticket_query_handler.handle ticket_store_module
        ~store_handle:ticket_store q
    with
    | None -> None
    | Some vm -> Some (View_models.Order_ticket_view_model.yojson_of_t vm)
  in
  let list_open_order_tickets () : Yojson.Safe.t list =
    let q : Queries.List_open_order_tickets_query.t = { book_id = None } in
    Queries.List_open_order_tickets_query_handler.handle ticket_store_module
      ~store_handle:ticket_store q
    |> List.map View_models.Order_ticket_view_model.yojson_of_t
  in
  let cancel_order_ticket ~ticket_id ~body :
      Execution_management_inbound_http.Http.cancel_result =
    let parsed =
      if body = "" then
        (* Body omitted: default reason "operator". *)
        Some
          ({ ticket_id; reason = "operator" }
            : Cmds.Cancel_order_ticket_command.t)
      else
        try
          let cmd = Cmds.Cancel_order_ticket_command.t_of_string body in
          Some { cmd with ticket_id }
        with _ -> None
    in
    match parsed with
    | None -> Cancel_invalid_payload "malformed JSON body"
    | Some cmd -> (
        with_lock (fun () ->
            match
              Cmds.Cancel_order_ticket_command_workflow.execute
                ~store:ticket_store_module ~store_handle:ticket_store
                ~publish:publish_aggregate_event ~now cmd
            with
            | Ok () -> Execution_management_inbound_http.Http.Cancel_ok
            | Error errs ->
                let not_found =
                  List.exists
                    (function
                      | Cmds.Command_error.Ticket_not_found _ -> true
                      | _ -> false)
                    errs
                in
                if not_found then Cancel_not_found
                else
                  let msg =
                    match errs with
                    | Cmds.Command_error.Invalid_payload m :: _ -> m
                    | _ -> "cancel rejected"
                  in
                  Cancel_invalid_payload msg))
  in
  let http_handler =
    Execution_management_inbound_http.Http.make_handler ~get_order_ticket
      ~list_open_order_tickets ~cancel_order_ticket ()
  in
  { http_handler }

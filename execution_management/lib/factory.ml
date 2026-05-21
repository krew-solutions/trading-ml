module Inbound = Execution_management_external_integration_events
module Outbound_ie = Execution_management_integration_events
module Cmds = Execution_management_commands
module Ports = Execution_management_ports
module Persistence = Execution_management_persistence
module Feeds = Execution_management_feeds
module View_models = Execution_management_view_models
module Queries = Execution_management_queries
module Ot = Execution_management.Order_ticket

type t = { http_handler : Inbound_http.Route.handler }

(** Wire-format DTOs for cross-BC commands EMS dispatches over the
    bus. Kept factory-local to avoid importing the receiving BCs'
    command libraries (per ADR-0001's BC-independence rule); each
    wire shape is fixed by the consumer-side .atd. *)

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

type wire_cancel = { correlation_id : string; placement_id : int } [@@deriving yojson]

(** Wire-format placement_id encoding: the OrderTicket aggregate
    mints local sequence ids (1, 2, 3, ...) per ticket; the
    factory translates to a globally-unique wire id for broker
    correlation. Reversible so inbound broker IEs decode back to
    ticket_id at the ACL boundary. *)
let placement_id_seq_capacity = 1_000_000

let encode_wire_placement_id ~ticket_id ~local_seq =
  (ticket_id * placement_id_seq_capacity) + local_seq

let decode_wire_to_ticket_id wire_pid = wire_pid / placement_id_seq_capacity

let to_wire_kind (k : Ot.Placement.Values.Order_kind.t) : wire_order_kind =
  match k with
  | Market -> { type_ = "MARKET"; price = None; stop_price = None; limit_price = None }
  | Limit { price } ->
      {
        type_ = "LIMIT";
        price = Some (Decimal.to_string price);
        stop_price = None;
        limit_price = None;
      }
  | Stop { stop_price } ->
      {
        type_ = "STOP";
        price = None;
        stop_price = Some (Decimal.to_string stop_price);
        limit_price = None;
      }
  | Stop_limit { stop_price; limit_price } ->
      {
        type_ = "STOP_LIMIT";
        price = None;
        stop_price = Some (Decimal.to_string stop_price);
        limit_price = Some (Decimal.to_string limit_price);
      }

let to_wire_tif (t : Ot.Placement.Values.Tif.t) : string =
  match t with
  | Gtc -> "GTC"
  | Day -> "DAY"
  | Ioc -> "IOC"
  | Fok -> "FOK"

let build ~bus ~now : t =
  let mu = Mutex.create () in
  let with_lock f =
    Mutex.lock mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock mu) f
  in

  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
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
  let publish_ticket_fill_recorded =
    produce ~uri:"in-memory://execution-management.order-ticket-fill-recorded"
      ~yojson_of:Outbound_ie.Order_ticket_fill_recorded_integration_event.yojson_of_t
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
     correlation_by_ticket is populated when Open_order_ticket_command
     arrives from order_management; downstream broker dispatches and
     outbound IEs read from it. *)
  let ticket_store = Persistence.In_memory_ticket_store.create () in
  let ticket_store_module :
      (module Ports.Ticket_store.S with type t = Persistence.In_memory_ticket_store.t) =
    (module Persistence.In_memory_ticket_store)
  in
  let correlation_by_ticket : (int, string) Hashtbl.t = Hashtbl.create 64 in
  let ticket_intent : (int, Ot.Values.Trade_intent.t) Hashtbl.t = Hashtbl.create 64 in
  let reservation_by_ticket : (int, Ot.Values.Reservation_id.t) Hashtbl.t =
    Hashtbl.create 64
  in
  let correlation_for tid =
    Option.value (Hashtbl.find_opt correlation_by_ticket tid) ~default:""
  in

  (* Volume-feed and market-data adapters. The single subscriber
     on [broker.bar-updated] fans every bar into both ports — POV
     attaches to the volume feed at Ticket_opened; the market-data
     adapter is live but currently has no domain consumer (kept
     ready for mark-to-market / adaptive-strategy follow-ups). *)
  let volume_feed = Feeds.Broker_volume_feed.create () in
  let market_data = Feeds.Broker_market_data.create () in
  let volume_subscription_by_ticket :
      (int, Feeds.Broker_volume_feed.subscription) Hashtbl.t =
    Hashtbl.create 16
  in
  let detach_volume_subscription tid =
    match Hashtbl.find_opt volume_subscription_by_ticket tid with
    | None -> ()
    | Some sub ->
        Feeds.Broker_volume_feed.unsubscribe volume_feed sub;
        Hashtbl.remove volume_subscription_by_ticket tid
  in

  let rec publish_aggregate_event (ev : Ot.event) : unit =
    match ev with
    | Ev_ticket_opened e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        Hashtbl.replace ticket_intent tid e.intent;
        Hashtbl.replace reservation_by_ticket tid e.reservation_id;
        (match e.directive with
        | Ot.Values.Execution_directive.Pov params ->
            let sub =
              Feeds.Broker_volume_feed.subscribe volume_feed
                ~instrument:e.intent.instrument ~timeframe:params.timeframe
                ~on_bar:(fun bar -> dispatch_volume_bar ~ticket_id:tid bar)
            in
            Hashtbl.replace volume_subscription_by_ticket tid sub
        | _ -> ());
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
          (Outbound_ie.Order_ticket_failed_integration_event.of_domain ~correlation_id e);
        detach_volume_subscription tid;
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid;
        Hashtbl.remove reservation_by_ticket tid
    | Ev_ticket_cancelled e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        publish_ticket_cancelled
          (Outbound_ie.Order_ticket_cancelled_integration_event.of_domain ~correlation_id
             e);
        detach_volume_subscription tid;
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid;
        Hashtbl.remove reservation_by_ticket tid
    | Ev_ticket_completed e ->
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        publish_ticket_completed
          (Outbound_ie.Order_ticket_completed_integration_event.of_domain ~correlation_id
             e);
        detach_volume_subscription tid;
        Hashtbl.remove correlation_by_ticket tid;
        Hashtbl.remove ticket_intent tid;
        Hashtbl.remove reservation_by_ticket tid
    | Ev_placement_filled e -> (
        let tid = Ot.Values.Ticket_id.to_int e.ticket_id in
        let correlation_id = correlation_for tid in
        match Hashtbl.find_opt reservation_by_ticket tid with
        | None ->
            ()
            (* Should never happen: Ev_ticket_opened populates the map
               before any Placement_filled can land. Silent drop is safer
               than a crash on a future ordering edge case. *)
        | Some reservation_id ->
            publish_ticket_fill_recorded
              (Outbound_ie.Order_ticket_fill_recorded_integration_event.of_domain
                 ~correlation_id ~reservation_id e))
    | Ev_placement_acknowledged _
    | Ev_placement_rejected _
    | Ev_placement_unreachable _
    | Ev_placement_cancelled _ -> ()
  and dispatch_volume_bar ~ticket_id (bar : Ot.Values.Volume_bar.t) =
    with_lock (fun () ->
        let cmd : Cmds.Ingest_volume_bar_command.t =
          { ticket_id; bar_ts = bar.ts; bar_volume = Decimal.to_string bar.volume }
        in
        let _ =
          Cmds.Ingest_volume_bar_command_workflow.execute ~store:ticket_store_module
            ~store_handle:ticket_store ~publish:publish_aggregate_event ~now cmd
        in
        ())
  in

  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in

  (* Inbound cross-BC command from order_management. The intake
     gate now lives in pre_trade_risk (ADR 0020 + step 2.5
     follow-up); EM unconditionally opens the OrderTicket on every
     command it receives. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://execution-management.open-order-ticket-command"
         ~group:"execution-management-open-ticket"
         ~t_of_yojson:Cmds.Open_order_ticket_command.t_of_yojson)
      (fun (cmd : Cmds.Open_order_ticket_command.t) ->
        with_lock (fun () ->
            Hashtbl.replace correlation_by_ticket cmd.reservation_id cmd.correlation_id;
            let _ =
              Cmds.Open_order_ticket_command_workflow.execute ~store:ticket_store_module
                ~store_handle:ticket_store ~publish:publish_aggregate_event ~now cmd
            in
            ()))
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
        Inbound.Order_accepted_integration_event_handler.handle ~store:ticket_store_module
          ~store_handle:ticket_store ~publish:publish_aggregate_event ~now
          ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-leg-filled"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_leg_filled_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_leg_filled_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-rejected"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_rejected_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_rejected_integration_event_handler.handle ~store:ticket_store_module
          ~store_handle:ticket_store ~publish:publish_aggregate_event ~now
          ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-unreachable"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_unreachable_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_unreachable_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-cancelled"
         ~group:"execution-management-order-ticket"
         ~t_of_yojson:Inbound.Order_cancelled_integration_event.t_of_yojson) (fun ev ->
        Inbound.Order_cancelled_integration_event_handler.handle
          ~store:ticket_store_module ~store_handle:ticket_store
          ~publish:publish_aggregate_event ~now ~ticket_id_of_placement_id ev)
  in
  (* Broker bar feed → fan-out to volume_feed and market_data
     adapters (ADR 0023). One bus subscription, two ports. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.bar-updated"
         ~group:"execution-management-bar-feed"
         ~t_of_yojson:Inbound.Bar_updated_integration_event.t_of_yojson) (fun ev ->
        Inbound.Bar_updated_integration_event_handler.handle
          ~deliver_volume_bar:(fun ~instrument ~timeframe ~bar ->
            Feeds.Broker_volume_feed.deliver volume_feed ~instrument ~timeframe ~bar)
          ~deliver_market_data:(fun ~instrument ~quote ->
            Feeds.Broker_market_data.deliver market_data ~instrument ~quote)
          ev)
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
        Some ({ ticket_id; reason = "operator" } : Cmds.Cancel_order_ticket_command.t)
      else
        try
          let cmd = Cmds.Cancel_order_ticket_command.t_of_string body in
          Some { cmd with ticket_id }
        with _ -> None
    in
    match parsed with
    | None -> Cancel_invalid_payload "malformed JSON body"
    | Some cmd ->
        with_lock (fun () ->
            match
              Cmds.Cancel_order_ticket_command_workflow.execute ~store:ticket_store_module
                ~store_handle:ticket_store ~publish:publish_aggregate_event ~now cmd
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
                  Cancel_invalid_payload msg)
  in
  let http_handler =
    Execution_management_inbound_http.Http.make_handler ~get_order_ticket
      ~list_open_order_tickets ~cancel_order_ticket ()
  in
  { http_handler }

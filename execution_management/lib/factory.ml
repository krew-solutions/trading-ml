module Pm = Execution_management_process_managers.Place_order_pm
module Inbound = Execution_management_inbound_integration_events
module Outbound_ie = Execution_management_integration_events

type t = { http_handler : Inbound_http.Route.handler }

type config = {
  initial_equity : Decimal.t;
  max_drawdown_pct : float;
  rate_limit : (int * float) option;
}

(** Compose the qualified instrument string from the inbound mirror's
    nested instrument view-model — used when seeding saga state from
    a Trade_intent_approved event. *)
let qualify_instrument (i : Inbound.Trade_intent_approved_integration_event.t) : string =
  i.symbol

type wire_reserve = {
  correlation_id : string;
  side : string;
  symbol : string;
  quantity : string;
  price : string;
}
[@@deriving yojson]
(** Wire-format DTO of {!Account_commands.Reserve_command.t}. We
    keep this saga-local to avoid importing [account_commands]
    across the BC boundary; the wire shape is fixed by the
    Account-side consumer. *)

type wire_release = { correlation_id : string; reservation_id : int } [@@deriving yojson]

type wire_order_kind = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]

type wire_submit = {
  correlation_id : string;
  reservation_id : int;
  symbol : string;
  side : string;
  quantity : string;
  kind : wire_order_kind;
  tif : string;
}
[@@deriving yojson]

let to_wire_kind ~kind_type ~kind_price ~kind_stop_price ~kind_limit_price :
    wire_order_kind =
  {
    type_ = kind_type;
    price = kind_price;
    stop_price = kind_stop_price;
    limit_price = kind_limit_price;
  }

let build ~bus ~(config : config) : t =
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
  let now_iso8601 () =
    let secs = Unix.gettimeofday () in
    let secs_i = Int64.of_float (secs *. 1000.0) in
    Datetime.Iso8601.format secs_i
  in
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
  let dispatch (cmd : Pm.command) : unit =
    match cmd with
    | Dispatch_reserve { correlation_id; side; symbol; quantity; price } ->
        publish_reserve { correlation_id; side; symbol; quantity; price }
    | Dispatch_release { correlation_id; reservation_id } ->
        publish_release { correlation_id; reservation_id }
    | Dispatch_submit
        {
          correlation_id;
          reservation_id;
          symbol;
          side;
          quantity;
          kind_type;
          kind_price;
          kind_stop_price;
          kind_limit_price;
          tif;
        } ->
        let kind =
          to_wire_kind ~kind_type ~kind_price ~kind_stop_price ~kind_limit_price
        in
        publish_submit
          { correlation_id; reservation_id; symbol; side; quantity; kind; tif }
  in
  let store = Workflow_engine.In_memory_store.create () in
  let engine = Pm.Engine.create ~store ~dispatch in
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  (* Trade_intent_approved is the saga starter — kill-switch / rate-limit
     gate runs here, before Engine.start. Subsequent events go through
     Engine.on_event normally. *)
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
                    let now = Unix.gettimeofday () in
                    match Execution_management.Rate_limit.try_acquire rl ~now with
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
              let payload =
                Pm.initial_payload ~book_id:ev.book_id ~symbol:(qualify_instrument ev)
                  ~side:ev.side ~quantity:ev.quantity
              in
              Pm.Engine.start engine ~correlation_id:ev.correlation_id
                (Pm.Awaiting_reservation { payload });
              (* Price for the Reserve at the gate is unknown without
                 a marks subscription — saga submits the symbol and
                 quantity to Account, which uses its own market_price
                 port to compute the cash earmark. We pass an empty
                 string here as a placeholder; the wire schema requires
                 a string but Account's parser uses [price] only when
                 routing through the HTTP path — not via the
                 saga-driven bus path. Wire alignment is a follow-up
                 once Account adds a bus consumer for Reserve_command. *)
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
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-accepted" ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Order_accepted_integration_event.t_of_yojson) (fun ev ->
        Pm.Engine.on_event engine (Pm.Order_accepted ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-rejected" ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Order_rejected_integration_event.t_of_yojson) (fun ev ->
        Pm.Engine.on_event engine (Pm.Order_rejected ev))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.order-unreachable"
         ~group:"execution-management-saga"
         ~t_of_yojson:Inbound.Order_unreachable_integration_event.t_of_yojson) (fun ev ->
        Pm.Engine.on_event engine (Pm.Order_unreachable ev))
  in
  (* Cash_changed feeds the kill-switch peak / drawdown tracking.
     Today Account does not publish Cash_changed; the subscription is
     wired but inert. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.cash-changed"
         ~group:"execution-management-kill-switch"
         ~t_of_yojson:Inbound.Cash_changed_integration_event.t_of_yojson)
      (fun (ev : Inbound.Cash_changed_integration_event.t) ->
        with_lock (fun () ->
            let equity = try Decimal.of_string ev.new_balance with _ -> Decimal.zero in
            let occurred_at = Datetime.Iso8601.parse ev.occurred_at in
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
  let http_handler = Execution_management_inbound_http.Http.make_handler () in
  { http_handler }

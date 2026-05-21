open Core
module Token_store = Broker_persistence.Token_store

(** Discriminated handle for an opened broker adapter — combines the
    abstract [Broker.client] (used by command/query ports) with the
    concrete REST handle and adapter that the WS bridge and reconcile
    fibers need direct reach into.

    Composition-root code (typically [bin/]) calls one of
    {!Opened.open_finam}, {!Opened.open_bcs}, {!Opened.open_synthetic}
    and passes the result to {!build}; nothing outside this module
    needs to know how a Finam / BCS / Synthetic adapter is wired
    internally. *)
module Opened = struct
  type t =
    | Finam of {
        client : Broker.client;
        rest : Finam.Rest.t;
        adapter : Finam.Finam_broker.t;
            (** Concrete adapter kept alongside the abstract client:
                the WS-side trade-update producer needs to reach the
                per-adapter placement map to reverse-lookup
                [order_id → placement_id]. *)
      }
    | Bcs of {
        client : Broker.client;
        rest : Bcs.Rest.t;
        adapter : Bcs.Bcs_broker.t;
            (** Same rationale as the Finam variant — the polling
                fiber that surfaces order fills reaches the
                per-adapter placement map to reverse-lookup
                [order_num → placement_id]. *)
      }
    | Synthetic of { client : Broker.client }

  let client : t -> Broker.client = function
    | Finam { client; _ } | Bcs { client; _ } | Synthetic { client } -> client

  (** Selects the env-var prefix per broker. Keeps CLI invocations
      single-flagged while letting users park credentials for several
      brokers side by side ([FINAM_SECRET], [BCS_SECRET], ...). *)
  let env_prefix = function
    | "bcs" -> "BCS"
    | _ -> "FINAM"

  (** State-file path for the persisted BCS refresh-token. Follows
      the XDG Base Directory spec — [$XDG_STATE_HOME], with
      [~/.local/state] as the documented fallback. The file is
      [chmod 0o600] by {!Broker_persistence.Token_store.file}. *)
  let bcs_refresh_token_path () =
    let state_home =
      match Sys.getenv_opt "XDG_STATE_HOME" with
      | Some p when p <> "" -> p
      | _ -> Filename.concat (Sys.getenv "HOME") ".local/state"
    in
    let dir = Filename.concat state_home "trading" in
    (try Unix.mkdir dir 0o700 with Unix.Unix_error (EEXIST, _, _) -> ());
    Filename.concat dir "bcs-refresh-token"

  let open_finam ~env ~secret ~account_id : t =
    let cfg = Finam.Config.make ~account_id ~secret () in
    let transport = Http_transport.make_eio ~env in
    let rest = Finam.Rest.make ~transport ~cfg in
    let adapter = Finam.Finam_broker.make ~account_id rest in
    Finam { client = Finam.Finam_broker.as_broker adapter; rest; adapter }

  (** Credential sources, in precedence order:
      1. [?secret] — when present, seeds the persistent file
         immediately, then reads from it. Use for first-time setup
         or to force-overwrite a stale rotated token.
      2. Persistent file at {!bcs_refresh_token_path} — authoritative
         once populated. Keycloak rotations ([refresh_token] in the
         /token response) land here automatically.
      3. [BCS_SECRET] env var — bootstrap fallback when the file
         is still empty. Same env convention as Finam uses.

      [?client_id] must match the Keycloak client under which the
      refresh-token was issued (BCS portal distinguishes
      [trade-api-read] for data and [trade-api-write] for orders). *)
  let open_bcs ~env ?secret ?account_id ?client_id () : t =
    let file_path = bcs_refresh_token_path () in
    let file_store = Token_store.file ~path:file_path in
    (match secret with
    | Some s -> Token_store.save file_store s
    | None -> ());
    let token_store =
      Token_store.fallback file_store (Token_store.env ~name:"BCS_SECRET")
    in
    let cfg = Bcs.Config.make ?account_id ?client_id () in
    let transport = Http_transport.make_eio ~env in
    let rest = Bcs.Rest.make ~transport ~cfg ~token_store in
    let adapter = Bcs.Bcs_broker.make rest in
    Bcs { client = Bcs.Bcs_broker.as_broker adapter; rest; adapter }

  let open_synthetic () : t =
    let adapter = Synthetic.Synthetic_broker.make () in
    Synthetic { client = Synthetic.Synthetic_broker.as_broker adapter }
end

type t = {
  client : Broker.client;
  market_price : instrument:Instrument.t -> Decimal.t;
  ws_setup : (sw:Eio.Switch.t -> Server.Http.live_setup) option;
  http_handler : Inbound_http.Route.handler;
}

let build ~bus ~env ~now ~(opened : Opened.t) ~paper_mode : t =
  let client = Opened.client opened in
  let now_ts : unit -> int64 = now in
  let market_price ~instrument =
    match Broker.bars client ~n:1 ~instrument ~timeframe:Timeframe.H1 with
    | last :: _ -> last.close
    | [] -> Decimal.zero
  in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_order_accepted =
    produce ~uri:"in-memory://broker.order-accepted"
      ~yojson_of:Broker_integration_events.Order_accepted_integration_event.yojson_of_t
  in
  let publish_order_rejected =
    produce ~uri:"in-memory://broker.order-rejected"
      ~yojson_of:Broker_integration_events.Order_rejected_integration_event.yojson_of_t
  in
  let publish_order_unreachable =
    produce ~uri:"in-memory://broker.order-unreachable"
      ~yojson_of:Broker_integration_events.Order_unreachable_integration_event.yojson_of_t
  in
  let publish_order_cancelled =
    produce ~uri:"in-memory://broker.order-cancelled"
      ~yojson_of:Broker_integration_events.Order_cancelled_integration_event.yojson_of_t
  in
  (* Outbound publisher for [broker.bar-updated]. Stateful — owns the
     per-(instrument, timeframe) monotonicity + intra-bar dedup
     invariants. See
     {!Broker_ohs_integration_events.Bar_updated_integration_event_publisher}
     for the filtering rules and the forward direction (the
     [Bar_series] aggregate that will replace this prototype with
     a real logical clock keyed by
     [(stream_type, stream_id, stream_position)]). *)
  let publish_bar_updated =
    Broker_ohs_integration_events.Bar_updated_integration_event_publisher.make ~bus
  in
  let publish_order_filled =
    produce ~uri:"in-memory://broker.order-leg-filled"
      ~yojson_of:Broker_integration_events.Order_leg_filled_integration_event.yojson_of_t
  in
  (* Process-correlation log: [placement_id ↦ submit/cancel
     correlation_id]. Recorded by Submit on Accepted (and, when
     wired, Cancel); future fill-from-WS events that arrive
     outside command-in-scope will read it back to stamp the
     outbound IE with the originating saga. In-memory for now. *)
  let command_log : Broker_persistence.In_memory_order_command_log.t =
    Broker_persistence.In_memory_order_command_log.create ()
  in
  let command_log_module =
    (module Broker_persistence.In_memory_order_command_log
    : Broker_store.Order_command_log.S
      with type t = Broker_persistence.In_memory_order_command_log.t)
  in
  (* In paper_mode the [paper_broker] BC handles the saga's
     submit_order and cancel_pending_order traffic via its own
     subscriptions. Broker's subscribers would otherwise also
     accept the same wire formats and route them through the live
     source client, which for synthetic/finam/bcs does not really
     place or cancel orders. To avoid double-handling, we skip
     both subscriptions here when paper_mode is on. *)
  (if not paper_mode then
     let dispatch_submit_order (cmd : Broker_commands.Submit_order_command.t) =
       match
         Broker_commands.Submit_order_command_workflow.execute ~broker:client
           ~command_log:command_log_module ~command_log_handle:command_log
           ~publish_accepted:publish_order_accepted
           ~publish_rejected:publish_order_rejected
           ~publish_unreachable:publish_order_unreachable cmd
       with
       | Ok () -> ()
       | Error _ ->
           (* Validation failures already surfaced as Order_unreachable
              IE by the workflow; the Rop tail is discarded. *)
           ()
     in
     let dispatch_cancel_pending_order
         (cmd : Broker_commands.Cancel_pending_order_command.t) =
       match
         Broker_commands.Cancel_pending_order_command_workflow.execute ~broker:client
           ~command_log:command_log_module ~command_log_handle:command_log ~now_ts
           ~publish_order_cancelled cmd
       with
       | Ok () -> ()
       | Error errs ->
           List.iter
             (function
               | Broker_commands.Cancel_pending_order_command_handler.Resolution e ->
                   Log.warn "[broker cancel] %s"
                     (Broker_commands.Cancel_pending_order_command_handler
                      .resolution_error_to_string e))
             errs
     in
     let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer
         =
       Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
           t_of_yojson (Yojson.Safe.from_string s))
     in
     let _ : Bus.subscription =
       Bus.subscribe
         (consume ~uri:"in-memory://broker.submit-order-command" ~group:"broker-saga"
            ~t_of_yojson:Broker_commands.Submit_order_command.t_of_yojson)
         dispatch_submit_order
     in
     let _ : Bus.subscription =
       Bus.subscribe
         (consume ~uri:"in-memory://broker.cancel-pending-order-command"
            ~group:"broker-saga"
            ~t_of_yojson:Broker_commands.Cancel_pending_order_command.t_of_yojson)
         dispatch_cancel_pending_order
     in
     ()
   else
     (* Held in scope so the unused-binding warnings don't fire when
        the publishers and the command log are only consumed by the
        gated branch. Their bus producers remain registered (and
        thus reachable for any future direct caller) regardless of
        [paper_mode]. *)
     let _ =
       ( publish_order_accepted,
         publish_order_rejected,
         publish_order_unreachable,
         publish_order_cancelled,
         command_log,
         now_ts )
     in
     ());
  let origin_correlation_id ~placement_id =
    let module CL = (val command_log_module) in
    CL.origin_correlation_id command_log ~placement_id
  in
  (* Construct [Server.Http.live_setup] for live adapters; the
     setup closure spawns the adapter's WS / poll machinery on
     the server's switch and exposes per-key lifecycle hooks
     [on_first] / [on_last] for SSE-driven subscriptions.

     [on_event] is the single seam through which all events
     flow from adapter to application. Bars route to the OHS
     publisher (monotonicity + intra-bar dedup → bus) and to
     the SSE Stream registry (UI live ticks). [Order_filled]
     events get correlation-id stamping, cumulative-fill
     accumulation, and IE construction here, then publish on
     [broker.order-leg-filled]. *)
  let ws_setup =
    match opened with
    | Opened.Synthetic _ -> None
    | Opened.Finam _ | Opened.Bcs _ ->
        Some
          (fun ~sw ->
            let registry_ref : Server.Stream.t option ref = ref None in
            let on_event (event : Broker.event) =
              match event with
              | Remote_bar_updated ev -> (
                  Broker_domain_event_handlers.Publish_integration_event_on_bar_updated
                  .handle ~publish_bar_updated ev;
                  match !registry_ref with
                  | Some r ->
                      Server.Stream.push_from_upstream r ~instrument:ev.instrument
                        ~timeframe:ev.timeframe ev.candle
                  | None -> ())
              | Order_leg_filled domain_ev ->
                  Broker_domain_event_handlers
                  .Publish_integration_event_on_order_leg_filled
                  .handle ~publish_order_leg_filled:publish_order_filled
                    ~origin_correlation_id domain_ev
            in
            Broker.start_live_feed client ~sw ~env ~on_event;
            Server.Http.
              {
                on_first =
                  (fun ~instrument ~timeframe ->
                    try Broker.subscribe client (Subscribe_bars { instrument; timeframe })
                    with e ->
                      Log.warn "[broker] subscribe failed: %s" (Printexc.to_string e));
                on_last =
                  (fun ~instrument ~timeframe ->
                    try
                      Broker.unsubscribe client (Subscribe_bars { instrument; timeframe })
                    with e ->
                      Log.warn "[broker] unsubscribe failed: %s" (Printexc.to_string e));
                bind = (fun r -> registry_ref := Some r);
              })
  in
  let http_handler = Broker_inbound_http.Http.make_handler ~broker:client in
  { client; market_price; ws_setup; http_handler }

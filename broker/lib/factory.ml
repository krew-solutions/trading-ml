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
    | Alor of {
        client : Broker.client;
        rest : Alor.Rest.t;
        adapter : Alor.Alor_broker.t;
            (** Same rationale as the Finam / BCS variants — the fill
                supervisor reaches the per-adapter placement map to
                reverse-lookup [order_id → placement_id]. *)
      }
    | Finam_grpc of {
        client : Broker.client;
        adapter : Finam_grpc.Finam_grpc_broker.t;
            (** Pure-gRPC Finam adapter (ADR 0033). No separate REST handle: gRPC
                multiplexes unary + streaming over one channel, and the live feed
                is driven through {!Broker.start_live_feed} like every other
                adapter. Kept alongside the abstract client for symmetry / direct
                reach, as the Finam/BCS/Alor variants do. *)
      }
    | Synthetic of { client : Broker.client }

  let client : t -> Broker.client = function
    | Finam { client; _ }
    | Bcs { client; _ }
    | Alor { client; _ }
    | Finam_grpc { client; _ }
    | Synthetic { client } -> client

  (** Selects the env-var prefix per broker. Keeps CLI invocations
      single-flagged while letting users park credentials for several
      brokers side by side ([FINAM_SECRET], [BCS_SECRET], [ALOR_SECRET], ...). *)
  let env_prefix = function
    | "bcs" -> "BCS"
    | "alor" -> "ALOR"
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

  (** Pure-gRPC Finam adapter (ADR 0033). Reuses the same credentials as the REST
      [open_finam] (portal [secret] + [account_id], i.e. the FINAM env prefix):
      it is the same venue over a different transport. The gRPC channel binds the
      host switch lazily at [start_live_feed], so no [~sw] is needed here. *)
  let open_finam_grpc ~env ~secret ~account_id : t =
    let cfg = Finam_grpc.Config.make ~secret () in
    let client = Finam_grpc.Client.create ~env cfg in
    let adapter = Finam_grpc.Finam_grpc_broker.make ~account_id client in
    Finam_grpc { client = Finam_grpc.Finam_grpc_broker.as_broker adapter; adapter }

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

  (** Alor scopes its API by [portfolio] (baked into the adapter) and a
      long-lived [refresh_token]. The token does not rotate, so there is
      no persistent store: it is taken from [?secret] or, failing that,
      the [ALOR_SECRET] env var. [?exchange] overrides the default venue
      ([MOEX]) used for account-wide calls. *)
  let open_alor ~env ?secret ?exchange ~portfolio () : t =
    let refresh_token =
      match secret with
      | Some s when s <> "" -> s
      | _ -> (
          match Sys.getenv_opt "ALOR_SECRET" with
          | Some s when s <> "" -> s
          | _ ->
              failwith
                "Alor: refresh token required (config secret or ALOR_SECRET env var)")
    in
    let cfg = Alor.Config.make ~refresh_token ~portfolio ?default_exchange:exchange () in
    let transport = Http_transport.make_eio ~env in
    let rest = Alor.Rest.make ~transport ~cfg in
    let adapter = Alor.Alor_broker.make rest in
    Alor { client = Alor.Alor_broker.as_broker adapter; rest; adapter }

  (* [~now] is the composition root's clock (Unix in live, Virtual in
     backtest). The synthetic adapter anchors both its bar history and
     its live generator to it so the candle series and the footprint
     tape share one timeline — the right edges coincide, as they do on a
     real broker. *)
  let open_synthetic ~now () : t =
    let adapter = Synthetic.Synthetic_broker.make ~now () in
    Synthetic { client = Synthetic.Synthetic_broker.as_broker adapter }
end

type t = {
  client : Broker.client;
  market_price : instrument:Instrument.t -> Decimal.t;
  http_handler : Inbound_http.Route.handler;
}

let build ~bus ~env ~sw ~now ~(opened : Opened.t) ~paper_mode ~watchlist : t =
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
  let publish_trade_executed =
    produce ~uri:"in-memory://broker.trade-executed"
      ~yojson_of:Broker_integration_events.Trade_executed_integration_event.yojson_of_t
  in
  (* Outbound publisher for [broker.public-trade-printed] — the public tape
     (all market participants), consumed by the order_flow BC for
     footprint analysis (ADR 0032). Stateless: tape prints carry no
     per-key monotonicity invariant; ordering/dedup are the
     subscriber inbox's concern. *)
  let publish_trade_printed =
    produce ~uri:"in-memory://broker.public-trade-printed"
      ~yojson_of:
        Broker_integration_events.Public_trade_printed_integration_event.yojson_of_t
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
  (* Bar-subscription commands. These are always wired — paper_mode
     gates only the order-routing subscriptions; bar feeds flow
     through this BC unconditionally (paper consumes the same
     [broker.bar-updated] topic for its fill simulation). *)
  let consume_command (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) :
      a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let dispatch_watch_bars (cmd : Broker_commands.Watch_bars_command.t) =
    match Broker_commands.Watch_bars_command_workflow.execute ~broker:client cmd with
    | Ok () | Error _ -> ()
  in
  let dispatch_unwatch_bars (cmd : Broker_commands.Unwatch_bars_command.t) =
    match Broker_commands.Unwatch_bars_command_workflow.execute ~broker:client cmd with
    | Ok () | Error _ -> ()
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume_command ~uri:"in-memory://broker.watch-bars-command"
         ~group:"broker-bar-subscription"
         ~t_of_yojson:Broker_commands.Watch_bars_command.t_of_yojson)
      dispatch_watch_bars
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume_command ~uri:"in-memory://broker.unwatch-bars-command"
         ~group:"broker-bar-subscription"
         ~t_of_yojson:Broker_commands.Unwatch_bars_command.t_of_yojson)
      dispatch_unwatch_bars
  in
  (* Public-trade (tape) subscription commands — the tape analogue of the
     bar-subscription commands. The order_flow BC issues these when a
     footprint subscription first needs (or last releases) an instrument's
     tape; the adapter-side refcount lets them coexist with the operator
     watchlist's own public-trade subscription. *)
  let dispatch_watch_public_trades (cmd : Broker_commands.Watch_public_trades_command.t) =
    match
      Broker_commands.Watch_public_trades_command_workflow.execute ~broker:client cmd
    with
    | Ok () | Error _ -> ()
  in
  let dispatch_unwatch_public_trades
      (cmd : Broker_commands.Unwatch_public_trades_command.t) =
    match
      Broker_commands.Unwatch_public_trades_command_workflow.execute ~broker:client cmd
    with
    | Ok () | Error _ -> ()
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume_command ~uri:"in-memory://broker.watch-public-trades-command"
         ~group:"broker-public-trade-subscription"
         ~t_of_yojson:Broker_commands.Watch_public_trades_command.t_of_yojson)
      dispatch_watch_public_trades
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume_command ~uri:"in-memory://broker.unwatch-public-trades-command"
         ~group:"broker-public-trade-subscription"
         ~t_of_yojson:Broker_commands.Unwatch_public_trades_command.t_of_yojson)
      dispatch_unwatch_public_trades
  in
  let origin_correlation_id ~placement_id =
    let module CL = (val command_log_module) in
    CL.origin_correlation_id command_log ~placement_id
  in
  (* Spin up the live adapter's event machinery on the host switch —
     Finam / BCS / Alor WS+poll, and now Synthetic's clock-driven
     generator (a live source symmetric to the real adapters through
     this port, so [serve --broker synthetic] drives bars and the
     footprint tape with no special casing here).

     [on_event] is the single seam through which all events flow
     from adapter to application. Bars route to the OHS publisher
     (the bus is the sole live-bar surface — SSE, strategy, paper,
     etc. all consume from there). [Trade_executed] events get
     correlation-id stamping and IE construction here, then publish
     on [broker.trade-executed]; [Public_trade_printed] prints
     publish on [broker.public-trade-printed]. *)
  let on_event (event : Broker.event) =
    match event with
    | Bar_updated ev ->
        Broker_domain_event_handlers.Publish_integration_event_on_bar_updated.handle
          ~publish_bar_updated ev
    | Trade_executed domain_ev ->
        Broker_domain_event_handlers.Publish_integration_event_on_trade_executed.handle
          ~publish_trade_executed ~origin_correlation_id domain_ev
    | Public_trade_printed ev ->
        Broker_domain_event_handlers.Publish_integration_event_on_public_trade_printed
        .handle ~publish_trade_printed ev
  in
  Broker.start_live_feed client ~sw ~env ~on_event;
  (* Apply the operator-declared watchlist: each entry opens an
     always-on bar subscription on the upstream adapter. The
     adapter's per-key refcount means a later SSE subscriber
     declaring interest in the same key coexists with the
     watchlist; only when both release does the upstream feed
     close. Errors per-entry are warned and skipped rather than
     fatal — a typo in one symbol must not block the host
     from starting. *)
  List.iter
    (fun (instrument, timeframe) ->
      try
        Broker.subscribe client (Subscribe_bars { instrument; timeframe });
        Log.info "watchlist: subscribed %s/%s"
          (Instrument.to_qualified instrument)
          (Timeframe.to_string timeframe)
      with e ->
        Log.warn "watchlist: %s/%s failed: %s"
          (Instrument.to_qualified instrument)
          (Timeframe.to_string timeframe)
          (Printexc.to_string e))
    watchlist;
  (* Public-tape (footprint) subscription for the distinct instruments
     in the watchlist: if we follow an instrument's bars, also relay its
     tape so the order_flow BC can build footprints (ADR 0032). Adapters
     that don't support it (BCS, Alor today) log and no-op. *)
  watchlist |> List.map fst
  |> List.sort_uniq Instrument.compare
  |> List.iter (fun instrument ->
      try
        Broker.subscribe client (Subscribe_public_trades { instrument });
        Log.info "watchlist: subscribed public-trades %s"
          (Instrument.to_qualified instrument)
      with e ->
        Log.warn "watchlist: public-trades %s failed: %s"
          (Instrument.to_qualified instrument)
          (Printexc.to_string e));
  (* The board this broker addresses instruments by, surfaced on
     /api/exchanges so the UI subscribes with the board-qualified id by
     default. BCS and Alor tag the board into the instrument identity
     (SBER@MISX/TQBR); Finam and Synthetic do not. Read from the opened
     adapter's config so it is not duplicated here. *)
  let default_board : string option =
    match opened with
    | Opened.Bcs { rest; _ } -> Some (Bcs.Rest.cfg rest).Bcs.Config.default_class_code
    | Opened.Alor { rest; _ } -> (Alor.Rest.cfg rest).Alor.Config.default_board
    | Opened.Finam _ | Opened.Finam_grpc _ | Opened.Synthetic _ -> None
  in
  let http_handler =
    Broker_inbound_http.Http.make_handler ~broker:client ~default_board
  in
  { client; market_price; http_handler }

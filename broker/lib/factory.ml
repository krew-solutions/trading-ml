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

(** Build a {!Server.Http.live_setup} that bridges Finam's WebSocket
    feed into the SSE stream registry and into the bar-updated bus
    publisher. Connection happens up-front on the server's switch;
    per-key SUBSCRIBE/UNSUBSCRIBE messages flow on subscriber
    lifecycle hooks; inbound BARS events fan out via
    [Stream.push_from_upstream] and [publish_bar_updated]. *)
let finam_live_setup
    ~env
    ~publish_bar_updated
    ~publish_order_filled
    ~origin_correlation_id
    ~(finam : Finam.Finam_broker.t)
    (rest : Finam.Rest.t)
    ~sw : Server.Http.live_setup =
  let cfg = Finam.Rest.cfg rest in
  let auth = Finam.Rest.auth rest in
  let registry_ref : Server.Stream.t option ref = ref None in
  let bridge_ref : Finam.Ws_bridge.bridge option ref = ref None in
  (* Per-placement cumulative-fill accumulator. Finam ships each
     execution leg separately; [new_total_filled] is the sum of
     [fill_quantity] across every observed trade update for the
     same [placement_id]. Lives in process memory — survives only
     the adapter's lifetime, replayed on reconnect from the
     venue if needed via REST. *)
  let total_filled : (int, Decimal.t) Hashtbl.t = Hashtbl.create 16 in
  let push_to_stream ~instrument ~timeframe candle =
    match !registry_ref with
    | Some r -> Server.Stream.push_from_upstream r ~instrument ~timeframe candle
    | None -> ()
  in
  let timeframes_fallback instrument =
    match !bridge_ref with
    | None -> []
    | Some b -> Finam.Ws_bridge.timeframes_for_instrument b instrument
  in
  let on_event (ev : Finam.Ws.event) =
    match ev with
    | Bars b ->
        Finam.Ws.Events.Bars_handler.handle ~push_to_stream ~publish_bar_updated
          ~timeframes_fallback b
    | Trades trades ->
        Finam.Ws.Events.Trade_handler.handle ~finam ~origin_correlation_id ~total_filled
          ~publish_order_filled trades
    | Error_ev e -> Finam.Ws.Events.Error_handler.handle e
    | Lifecycle ev -> Finam.Ws.Events.Lifecycle_handler.handle ev
    | Quote _ | Other _ -> ()
  in
  let bridge = Finam.Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event in
  bridge_ref := Some bridge;
  (* Always-on trade subscription for the broker's account, so
     fills observed at the venue surface as Order_filled IEs
     without waiting for any per-instrument subscriber. *)
  (try
     Finam.Ws_bridge.subscribe_trades bridge
       ~account_id:(Finam.Finam_broker.account_id finam)
   with e -> Log.warn "[finam ws] subscribe_trades failed: %s" (Printexc.to_string e));
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
    }

(** Spawn a polling fiber that periodically reads BCS's
    account-wide deals feed (REST [/trades/search]) and
    publishes a [broker.order-filled] integration event for
    every new execution against an order this adapter placed.

    BCS's WS API exposes only public market data (candles,
    order book, anonymous trades, quotes) — there is no
    personal-account push channel for fills. Polling is the
    only available real-time signal for this broker, and the
    cost is acceptable for retail traffic (one REST call per
    [poll_interval] regardless of placement count).

    Deduplication: per [(placement_id, ts, quantity, price)]
    tuple. BCS's deal payload carries a [tradeNum] in its raw
    JSON, but our domain [Order.execution] does not surface it;
    a stable probabilistic key over the four numeric fields is
    adequate for retail volumes (two genuinely identical fills
    on the same millisecond on the same instrument at the same
    price for the same placement do not occur outside synthetic
    test traffic).

    [poll_interval] is a clock-bound waiting period in seconds;
    [now] is the injected clock the surrounding factory build
    already uses. *)
let bcs_polling_setup
    ~env
    ~poll_interval
    ~publish_order_filled
    ~origin_correlation_id
    ~(bcs : Bcs.Bcs_broker.t)
    ~sw : unit =
  let observed : (int * int64 * string * string, unit) Hashtbl.t = Hashtbl.create 128 in
  let total_filled : (int, Decimal.t) Hashtbl.t = Hashtbl.create 16 in
  let bump_total ~placement_id ~delta =
    let prev =
      match Hashtbl.find_opt total_filled placement_id with
      | Some d -> d
      | None -> Decimal.zero
    in
    let next = Decimal.add prev delta in
    Hashtbl.replace total_filled placement_id next;
    next
  in
  let now_ts () = Int64.of_float (Eio.Time.now (Eio.Stdenv.clock env)) in
  let poll_once () =
    let to_ts = now_ts () in
    (* Look back 5 minutes per poll — bounded recent window is
       enough to catch fills since the previous tick and the
       de-dup set filters anything we already published. *)
    let from_ts = Int64.sub to_ts 300L in
    let deals =
      try Bcs.Bcs_broker.recent_deals ~from_ts ~to_ts bcs
      with e ->
        Log.warn "[bcs poll] recent_deals failed: %s" (Printexc.to_string e);
        []
    in
    List.iter
      (fun (order_num, (exec : Broker_domain.Order.execution)) ->
        match Bcs.Bcs_broker.placement_id_by_order_num bcs ~order_num with
        | None -> ()
        | Some placement_id ->
            let key =
              ( placement_id,
                exec.ts,
                Decimal.to_string exec.quantity,
                Decimal.to_string exec.price )
            in
            if Hashtbl.mem observed key then ()
            else begin
              Hashtbl.replace observed key ();
              match origin_correlation_id ~placement_id with
              | None ->
                  Log.warn
                    "[bcs poll] deal for placement_id=%d has no Submit correlation_id; \
                     skipping"
                    placement_id
              | Some correlation_id ->
                  (* BCS's deal payload does not carry side per leg;
                     we derive it from the parent order resolved
                     through the placement store. Fee mirrors
                     Finam — Decimal.zero. Instrument is reachable
                     through Get_order, but the polling path
                     deliberately avoids per-deal extra REST calls
                     to stay within rate limits; the leg's
                     [instrument] is filled from the parent order
                     when [get_order] succeeds, else left as a
                     synthetic SBER@MISX placeholder so the IE
                     remains schema-valid. *)
                  let parent =
                    try Bcs.Bcs_broker.get_order bcs ~placement_id with _ -> None
                  in
                  let instrument =
                    match parent with
                    | Some o -> o.instrument
                    | None ->
                        Broker_view_models.Instrument_view_model.of_domain
                          (Core.Instrument.make
                             ~ticker:(Core.Ticker.of_string "UNKNOWN")
                             ~venue:(Core.Mic.of_string "MISX") ())
                  in
                  let side =
                    match parent with
                    | Some o -> o.side
                    | None -> "BUY"
                  in
                  let new_total = bump_total ~placement_id ~delta:exec.quantity in
                  let ie : Broker_integration_events.Order_filled_integration_event.t =
                    {
                      correlation_id;
                      placement_id;
                      id = order_num;
                      exec_id =
                        (* No first-class trade_id surfaced; the
                           composite probabilistic key serves as
                           identity for downstream audit. *)
                        Printf.sprintf "%s:%Ld:%s" order_num exec.ts
                          (Decimal.to_string exec.quantity);
                      instrument;
                      side;
                      fill_quantity = Decimal.to_string exec.quantity;
                      fill_price = Decimal.to_string exec.price;
                      fee = "0";
                      new_total_filled = Decimal.to_string new_total;
                      fill_ts = Datetime.Iso8601.format exec.ts;
                    }
                  in
                  publish_order_filled ie
            end)
      deals
  in
  Eio.Fiber.fork ~sw (fun () ->
      while true do
        (try poll_once ()
         with e -> Log.warn "[bcs poll] tick failed: %s" (Printexc.to_string e));
        Eio.Time.sleep (Eio.Stdenv.clock env) (Float.of_int poll_interval)
      done)

(** Build a {!Server.Http.live_setup} for BCS. Unlike Finam, BCS
    opens one socket per subscription, so the bridge defers connect
    to [on_first] and tears down on [on_last]. The BARS fan-out
    callback pushes directly into the registry via
    [Stream.push_from_upstream] and into [publish_bar_updated]. *)
let bcs_live_setup
    ~env
    ~publish_bar_updated
    ~publish_order_filled
    ~origin_correlation_id
    ~(bcs : Bcs.Bcs_broker.t)
    (rest : Bcs.Rest.t)
    ~sw : Server.Http.live_setup =
  let cfg = Bcs.Rest.cfg rest in
  let auth = Bcs.Rest.auth rest in
  let bridge = Bcs.Ws_bridge.make ~env ~sw ~cfg ~auth in
  let registry_ref : Server.Stream.t option ref = ref None in
  let push instrument timeframe candle =
    (match !registry_ref with
    | Some r -> Server.Stream.push_from_upstream r ~instrument ~timeframe candle
    | None -> ());
    publish_bar_updated
      (Broker_integration_events.Bar_updated_integration_event.of_domain ~instrument
         ~timeframe ~candle)
  in
  (* Always-on polling for personal-account fills — symmetric to
     Finam's always-on Sub_trades but via REST polling since BCS
     has no WS push for personal events. *)
  (try
     bcs_polling_setup ~env ~poll_interval:5 ~publish_order_filled ~origin_correlation_id
       ~bcs ~sw
   with e -> Log.warn "[bcs poll] setup failed: %s" (Printexc.to_string e));
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe ~on_candle:push
          with e -> Log.warn "[bcs ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[bcs ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
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
  let publish_bar_updated =
    produce ~uri:"in-memory://broker.bar-updated"
      ~yojson_of:Broker_integration_events.Bar_updated_integration_event.yojson_of_t
  in
  let publish_order_filled =
    produce ~uri:"in-memory://broker.order-filled"
      ~yojson_of:Broker_integration_events.Order_filled_integration_event.yojson_of_t
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
  let ws_setup =
    match opened with
    | Opened.Finam { rest; adapter; _ } ->
        Some
          (finam_live_setup ~env ~publish_bar_updated ~publish_order_filled
             ~origin_correlation_id ~finam:adapter rest)
    | Opened.Bcs { rest; adapter; _ } ->
        Some
          (bcs_live_setup ~env ~publish_bar_updated ~publish_order_filled
             ~origin_correlation_id ~bcs:adapter rest)
    | Opened.Synthetic _ -> None
  in
  let http_handler = Broker_inbound_http.Http.make_handler ~broker:client in
  { client; market_price; ws_setup; http_handler }

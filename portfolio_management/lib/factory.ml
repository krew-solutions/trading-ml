open Core

type t = { http_handler : Inbound_http.Route.handler }

let build ~bus ~now : t =
  (* In-memory per-book registries. Lazily allocated: the first
     reference to a book auto-creates an empty aggregate ref. No
     persistence today — restart wipes PM state. *)
  let target_portfolios :
      ( Portfolio_management.Common.Book_id.t,
        Portfolio_management.Target_portfolio.t ref )
      Hashtbl.t =
    Hashtbl.create 16
  in
  let actual_portfolios :
      ( Portfolio_management.Common.Book_id.t,
        Portfolio_management.Actual_portfolio.t ref )
      Hashtbl.t =
    Hashtbl.create 16
  in
  let alpha_views :
      ( Portfolio_management.Common.Alpha_source_id.t * Instrument.t,
        Portfolio_management.Alpha_view.t ref )
      Hashtbl.t =
    Hashtbl.create 16
  in
  (* Pair-mean-reversion state registry. Keyed by (book_id, pair) so
     two books can run independent pair-mr policies on the same Pair.t.
     Starts empty: today no caller registers states; when a future
     [Define_pair_mr_command] lands, its workflow will populate this
     table. The bar pipeline iterates whatever is here. *)
  let pair_mr_states :
      ( Portfolio_management.Common.Book_id.t * Portfolio_management.Common.Pair.t,
        Portfolio_management.Pair_mean_reversion.state ref )
      Hashtbl.t =
    Hashtbl.create 16
  in
  let pair_mr_states_for instrument =
    Hashtbl.fold
      (fun (_book, pair) state_ref acc ->
        if Portfolio_management.Common.Pair.contains pair instrument then state_ref :: acc
        else acc)
      pair_mr_states []
  in
  let target_portfolio_for_create book_id =
    match Hashtbl.find_opt target_portfolios book_id with
    | Some r -> r
    | None ->
        let r = ref (Portfolio_management.Target_portfolio.empty book_id) in
        Hashtbl.replace target_portfolios book_id r;
        r
  in
  let actual_portfolio_for_create book_id =
    match Hashtbl.find_opt actual_portfolios book_id with
    | Some r -> r
    | None ->
        let r = ref (Portfolio_management.Actual_portfolio.empty book_id) in
        Hashtbl.replace actual_portfolios book_id r;
        r
  in
  let actual_portfolio_for_create_or_none book_id =
    Some (actual_portfolio_for_create book_id)
  in
  let target_portfolio_for_or_none book_id =
    Option.map (fun r -> !r) (Hashtbl.find_opt target_portfolios book_id)
  in
  let actual_portfolio_for_reconcile book_id =
    Option.map (fun r -> !r) (Hashtbl.find_opt actual_portfolios book_id)
  in
  let alpha_view_for_create ~alpha_source_id ~instrument =
    match Hashtbl.find_opt alpha_views (alpha_source_id, instrument) with
    | Some r -> r
    | None ->
        let r =
          ref (Portfolio_management.Alpha_view.empty ~alpha_source_id ~instrument)
        in
        Hashtbl.replace alpha_views (alpha_source_id, instrument) r;
        r
  in
  (* TODO: replace with an Alpha_subscription registry aggregate.
     Today every alpha-direction flip fans out to the empty list, so
     no targets get rebalanced via the alpha pipeline. *)
  let subscribers_for ~alpha_source_id:_ ~instrument:_ :
      Portfolio_management.Common.Book_id.t list =
    []
  in
  (* TODO: replace with a Risk_config registry aggregate. Today the
     registry is empty, so the unified construction → sizing →
     clipping handler is a silent no-op for every book — both alpha
     and pair-MR paths fall through. When a future
     [Configure_risk_command] lands, this table holds the per-book
     entries it populates. *)
  let risk_configs :
      (Portfolio_management.Common.Book_id.t, Portfolio_management.Risk_config.t)
      Hashtbl.t =
    Hashtbl.create 8
  in
  let risk_config_for book_id = Hashtbl.find_opt risk_configs book_id in
  (* TODO: replace with an [Account.equity_view] subscription. Today's
     stub returns zero, which the sizing function collapses to zero
     [target_qty] sentinel. *)
  let total_equity_for _book_id = Decimal.zero in
  (* TODO: replace with a per-book mark cache populated from the
     broker bar feed (mirrors ADR 0023's EM subscription pattern).
     Today's stub returns zero for every instrument; the sizing
     sentinel collapses to zero qty in that case. *)
  let mark_for _book_id _instrument = Decimal.zero in
  (* TODO: replace with a per-instrument volatility provider backed
     either by an in-PM rolling stdev computation or by a [Volatility]
     IE from a future Indicators BC. Today's stub is unconditional
     [None] so any volatility-aware sizing policy refuses to size. *)
  let volatility_for _instrument = None in
  (* All books are sized by Equity_proportional today; future
     per-book divergence (vol-target on book A, Kelly on book B)
     plugs in here as a registry lookup. The closure captures the
     policy's config (unit for Equity_proportional). *)
  let sizing_for _book_id :
      Portfolio_management_domain_event_handlers
      .Build_target_on_construction_intent
      .sizing_fn =
    fun ~book_equity ~mark ~volatility intent ->
      Portfolio_management.Sizing_policy.Equity_proportional.size () ~book_equity
        ~mark ~volatility intent
  in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_target_portfolio_updated =
    produce ~uri:"in-memory://pm.target-portfolio-updated"
      ~yojson_of:
        Portfolio_management_integration_events.Target_portfolio_updated_integration_event
        .yojson_of_t
  in
  let publish_trade_intents_planned =
    produce ~uri:"in-memory://pm.trade-intents-planned"
      ~yojson_of:
        Portfolio_management_integration_events.Trade_intents_planned_integration_event
        .yojson_of_t
  in
  (* Workflow dispatch ports — direct calls into PM workflows.
     Match-discard the Rop tail, mirroring Account.Factory. *)
  let dispatch_commit_actual_fill cmd =
    match
      Portfolio_management_commands.Commit_actual_fill_command_workflow.execute
        ~actual_portfolio_for:actual_portfolio_for_create_or_none cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  let dispatch_set_target (cmd : Portfolio_management_commands.Set_target_command.t) =
    (* The set_target workflow takes a single [Target_portfolio.t ref],
       not a registry — caller resolves the book_id to a ref. The
       workflow re-parses [cmd.book_id] internally and validates;
       a parse failure here just drops the command. *)
    match
      try Some (Portfolio_management.Common.Book_id.of_string cmd.book_id)
      with Invalid_argument _ -> None
    with
    | None -> ()
    | Some book_id -> (
        let target_portfolio = target_portfolio_for_create book_id in
        match
          Portfolio_management_commands.Set_target_command_workflow.execute
            ~target_portfolio ~publish_target_portfolio_updated cmd
        with
        | Ok () -> ()
        | Error _ -> ())
  in
  let dispatch_reconcile cmd =
    match
      Portfolio_management_commands.Reconcile_command_workflow.execute
        ~target_portfolio_for:target_portfolio_for_or_none
        ~actual_portfolio_for:actual_portfolio_for_reconcile
        ~publish_trade_intents_planned cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  let dispatch_define_alpha_view cmd =
    match
      Portfolio_management_commands.Define_alpha_view_command_workflow.execute
        ~alpha_view_for:alpha_view_for_create ~subscribers_for ~risk_config_for
        ~total_equity_for ~mark_for ~volatility_for ~sizing_for
        ~target_portfolio_for:target_portfolio_for_create
        ~publish_target_portfolio_updated cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  let dispatch_apply_bar cmd =
    match
      Portfolio_management_commands.Apply_bar_command_workflow.execute
        ~pair_mr_states_for ~risk_config_for ~total_equity_for ~mark_for
        ~volatility_for ~sizing_for
        ~target_portfolio_for:target_portfolio_for_create
        ~publish_target_portfolio_updated cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  (* [dispatch_set_target] is reserved scaffolding for future external
     entries (PM HTTP route / CLI override / cross-BC import). No
     internal pipeline routes through it today — pair-mr applies
     proposals via [dispatch_apply_bar], alpha applies via the
     Direction_changed DE handler. Held in scope so the workflow keeps
     its end-to-end build coverage. *)
  let _ = dispatch_set_target in
  (* Held in scope but currently unused — no inbound source dispatches
     these commands today. When PM HTTP routes / Strategy → PM bridge /
     a scheduler appear, these closures move into [Http.make_handler]
     and into bridge subscribers without changes here. *)
  let _ = dispatch_reconcile in
  (* Eager inbound subscriptions on cross-BC outbound URIs. Today's
     publishers don't fully exist yet; the subscriptions sit inert
     until traffic arrives. Each consumer deserializes wire JSON
     into PM's own mirror DTO — the wire is the only cross-BC
     contract. *)
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-filled" ~group:"portfolio-management"
         ~t_of_yojson:
           Portfolio_management_external_integration_events
           .Reservation_filled_integration_event
           .t_of_yojson)
      (Portfolio_management_external_integration_events
       .Reservation_filled_integration_event_handler
       .handle ~now ~dispatch_commit_actual_fill)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://broker.bar-updated" ~group:"portfolio-management-pair-mr"
         ~t_of_yojson:
           Portfolio_management_external_integration_events.Bar_updated_integration_event
           .t_of_yojson)
      (Portfolio_management_external_integration_events
       .Bar_updated_integration_event_handler
       .handle ~dispatch_apply_bar)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://strategy.signal-detected"
         ~group:"portfolio-management-alpha"
         ~t_of_yojson:
           Portfolio_management_external_integration_events
           .Signal_detected_integration_event
           .t_of_yojson)
      (Portfolio_management_external_integration_events
       .Signal_detected_integration_event_handler
       .handle ~dispatch_define_alpha_view)
  in
  (* Hold registries in scope so future configuration commands can
     populate them — currently nothing dispatches into them. *)
  let _ = risk_configs in
  let http_handler = Portfolio_management_inbound_http.Http.make_handler () in
  { http_handler }

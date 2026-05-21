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
  (* In-memory registry of [Alpha_subscription.t] entries keyed by
     the pair [(alpha_source_id, instrument)]. Populated by the
     [Subscribe_book_to_alpha_command] workflow; consulted by the
     alpha-direction-changed handler to fan a flip out to every
     subscribing book.

     Idempotent insert: [persist_subscription] de-duplicates on
     the triplet via [Alpha_subscription.equal] before appending,
     so re-issuing the same command does not create a second
     entry. *)
  let alpha_subscriptions :
      ( Portfolio_management.Common.Alpha_source_id.t * Instrument.t,
        Portfolio_management.Common.Alpha_subscription.t list )
      Hashtbl.t =
    Hashtbl.create 16
  in
  let subscribers_for ~alpha_source_id ~instrument :
      Portfolio_management.Common.Book_id.t list =
    match Hashtbl.find_opt alpha_subscriptions (alpha_source_id, instrument) with
    | None -> []
    | Some subs ->
        List.map
          (fun (s : Portfolio_management.Common.Alpha_subscription.t) -> s.book_id)
          subs
  in
  let persist_subscription (sub : Portfolio_management.Common.Alpha_subscription.t) : unit
      =
    let key = (sub.alpha_source_id, sub.instrument) in
    let existing =
      match Hashtbl.find_opt alpha_subscriptions key with
      | Some xs -> xs
      | None -> []
    in
    if List.exists (Portfolio_management.Common.Alpha_subscription.equal sub) existing
    then ()
    else Hashtbl.replace alpha_subscriptions key (sub :: existing)
  in
  (* Per-book [Risk_config] registry. Populated by
     [Configure_risk_command_workflow]; consulted by the unified
     construction → sizing → clipping handler. When the registry
     contains no entry for a book, the unified handler is a silent
     no-op for that book — intents fall through harmlessly. *)
  let risk_configs :
      ( Portfolio_management.Common.Book_id.t,
        Portfolio_management.Risk_config.t )
      Hashtbl.t =
    Hashtbl.create 8
  in
  let risk_config_for book_id = Hashtbl.find_opt risk_configs book_id in
  let persist_risk_config book_id cfg = Hashtbl.replace risk_configs book_id cfg in
  (* Cross-book mark cache populated from [broker.bar-updated]
     (ADR 0023 pattern). Per-instrument, not per-book: every book
     uses the same last-close as its mark for the instrument. A
     missing entry returns zero — the sizing sentinel collapses to
     zero qty in that case. *)
  let marks : (Instrument.t, Decimal.t) Hashtbl.t = Hashtbl.create 64 in
  let update_mark (instrument : Instrument.t) ~(close : Decimal.t) : unit =
    if Decimal.is_positive close then Hashtbl.replace marks instrument close
  in
  let mark_lookup (instrument : Instrument.t) : Decimal.t =
    match Hashtbl.find_opt marks instrument with
    | Some p -> p
    | None -> Decimal.zero
  in
  let mark_for _book_id (instrument : Instrument.t) : Decimal.t =
    mark_lookup instrument
  in
  (* Per-instrument [Vol_state] registry. Populated lazily on the
     first bar observed for each instrument; updated thereafter
     on every successfully-parsed bar. [volatility_for] is the
     port the unified handler / vol-aware sizing consult.

     Window and annualisation_factor are global defaults here:
     hourly bars with [252 × 6.5 ≈ 1638] hourly periods per year
     would be the "right" factor for hourly intraday; we ship a
     daily-default [252] and a window of [20] until a future
     per-(book, timeframe) Vol_view aggregate lands. The
     [volatility_for] provider gracefully degrades to [None]
     during warmup. *)
  let vol_states : (Instrument.t, Portfolio_management.Common.Vol_state.t ref) Hashtbl.t =
    Hashtbl.create 64
  in
  let vol_window = 20 in
  let vol_annualisation_factor = 252.0 in
  let update_vol (instrument : Instrument.t) ~(close : Decimal.t) : unit =
    if Decimal.is_positive close then
      let state_ref =
        match Hashtbl.find_opt vol_states instrument with
        | Some r -> r
        | None ->
            let r =
              ref
                (Portfolio_management.Common.Vol_state.init ~window:vol_window
                   ~annualisation_factor:vol_annualisation_factor)
            in
            Hashtbl.replace vol_states instrument r;
            r
      in
      state_ref := Portfolio_management.Common.Vol_state.update !state_ref ~close
  in
  let volatility_for (instrument : Instrument.t) : Decimal.t option =
    match Hashtbl.find_opt vol_states instrument with
    | None -> None
    | Some r ->
        Option.map Portfolio_management.Common.Volatility.to_decimal
          (Portfolio_management.Common.Vol_state.current !r)
  in
  (* Total equity per book: [Actual_portfolio.equity] over the
     observed positions valued at the mark cache. Books without
     an Actual_portfolio entry yield zero — sizing collapses to
     zero qty downstream. *)
  let total_equity_for book_id =
    match Hashtbl.find_opt actual_portfolios book_id with
    | None -> Decimal.zero
    | Some ap_ref ->
        Portfolio_management.Actual_portfolio.equity !ap_ref ~mark:mark_lookup
  in
  (* Per-book sizing dispatch: each book's [Risk_config.sizing_policy]
     selects one of the [Sizing_policy.S] implementations. The
     closure resolves the choice at call time so that a future
     [Configure_risk_command] re-issued for the same book swaps
     the policy without disturbing the unified handler. *)
  let sizing_for book_id :
      Portfolio_management_domain_event_handlers.Build_target_on_construction_intent
      .sizing_fn =
   fun ~book_equity ~mark ~volatility intent ->
    let choice =
      match risk_config_for book_id with
      | Some cfg -> Portfolio_management.Risk_config.sizing_policy cfg
      | None ->
          (* Fallback for the no-config branch: silent no-op
               anyway downstream (the unified handler short-
               circuits on missing Risk_config), so the choice
               here is observationally irrelevant. *)
          Portfolio_management.Common.Sizing_policy_choice.Equity_proportional
    in
    match choice with
    | Portfolio_management.Common.Sizing_policy_choice.Equity_proportional ->
        Portfolio_management.Sizing_policy.Equity_proportional.size () ~book_equity ~mark
          ~volatility intent
    | Portfolio_management.Common.Sizing_policy_choice.Volatility_target
        { target_annual_vol } ->
        Portfolio_management.Sizing_policy.Volatility_target.size { target_annual_vol }
          ~book_equity ~mark ~volatility intent
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
      Portfolio_management_commands.Apply_bar_command_workflow.execute ~pair_mr_states_for
        ~update_mark ~update_vol ~risk_config_for ~total_equity_for ~mark_for
        ~volatility_for ~sizing_for ~target_portfolio_for:target_portfolio_for_create
        ~publish_target_portfolio_updated cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  (* Dispatch closures return the Rop result so the HTTP route can
     surface validation errors back to the operator. Other inbound
     paths (bus subscription, CLI) that fire-and-forget will
     match-discard the Error tail at the callsite. *)
  let dispatch_configure_risk cmd :
      ( unit,
        Portfolio_management_commands.Configure_risk_command_handler.handle_error )
      Rop.t =
    Portfolio_management_commands.Configure_risk_command_workflow.execute
      ~persist_risk_config cmd
  in
  let dispatch_subscribe_book_to_alpha cmd :
      ( unit,
        Portfolio_management_commands.Subscribe_book_to_alpha_command_handler.handle_error
      )
      Rop.t =
    Portfolio_management_commands.Subscribe_book_to_alpha_command_workflow.execute
      ~persist_subscription cmd
  in
  let persist_pair_mr_state ~book_id ~pair ~state =
    let key = (book_id, pair) in
    match Hashtbl.find_opt pair_mr_states key with
    | Some r -> r := state
    | None -> Hashtbl.replace pair_mr_states key (ref state)
  in
  let dispatch_define_pair_mr cmd :
      ( unit,
        Portfolio_management_commands.Define_pair_mr_command_handler.handle_error )
      Rop.t =
    Portfolio_management_commands.Define_pair_mr_command_workflow.execute
      ~persist_pair_mr_state cmd
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
  (* [risk_configs] is populated by [dispatch_configure_risk]; held
     in scope to keep the persist closure alive. *)
  let _ = risk_configs in
  let http_handler =
    Portfolio_management_inbound_http.Http.make_handler
      ~configure_risk:dispatch_configure_risk
      ~subscribe_book_to_alpha:dispatch_subscribe_book_to_alpha
      ~define_pair_mr:dispatch_define_pair_mr
  in
  { http_handler }

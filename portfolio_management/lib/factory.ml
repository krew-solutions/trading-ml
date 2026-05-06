open Core

type t = { http_handler : Inbound_http.Route.handler }

let build ~bus : t =
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
  let target_portfolio_for_create book_id =
    match Hashtbl.find_opt target_portfolios book_id with
    | Some r -> r
    | None ->
        let r = ref (Portfolio_management.Target_portfolio.empty book_id) in
        Hashtbl.replace target_portfolios book_id r;
        r
  in
  let actual_portfolio_for_or_none book_id = Hashtbl.find_opt actual_portfolios book_id in
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
  (* TODO: replace with a per-book Risk-config aggregate. Hardcoded
     across all books today. *)
  let notional_cap_for _book_id = Decimal.of_int 100_000 in
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
  let dispatch_change_cash cmd =
    match
      Portfolio_management_commands.Change_cash_command_workflow.execute
        ~actual_portfolio_for:actual_portfolio_for_or_none cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  let dispatch_change_position cmd =
    match
      Portfolio_management_commands.Change_position_command_workflow.execute
        ~actual_portfolio_for:actual_portfolio_for_or_none cmd
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
        ~alpha_view_for:alpha_view_for_create ~subscribers_for ~notional_cap_for
        ~target_portfolio_for:target_portfolio_for_create
        ~publish_target_portfolio_updated cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  (* Held in scope but currently unused — no inbound source dispatches
     these commands today. When PM HTTP routes / Strategy → PM bridge /
     a scheduler appear, these closures move into [Http.make_handler]
     and into bridge subscribers without changes here. *)
  let _ = dispatch_set_target in
  let _ = dispatch_reconcile in
  let _ = dispatch_define_alpha_view in
  (* Eager inbound subscriptions on Account-side outbound URIs.
     Account does not publish these today; the subscriptions sit
     inert until traffic arrives. Each consumer deserializes wire
     JSON into PM's own mirror DTO — the wire is the only
     cross-BC contract. *)
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.cash-changed" ~group:"portfolio-management"
         ~t_of_yojson:
           Portfolio_management_inbound_integration_events.Cash_changed_integration_event
           .t_of_yojson)
      (Portfolio_management_inbound_integration_events
       .Cash_changed_integration_event_handler
       .handle ~dispatch_change_cash)
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.position-changed" ~group:"portfolio-management"
         ~t_of_yojson:
           Portfolio_management_inbound_integration_events
           .Position_changed_integration_event
           .t_of_yojson)
      (Portfolio_management_inbound_integration_events
       .Position_changed_integration_event_handler
       .handle ~dispatch_change_position)
  in
  let http_handler = Portfolio_management_inbound_http.Http.make_handler () in
  { http_handler }

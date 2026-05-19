(** In-process test harness for the Portfolio Management BC.

    Drives the application-layer workflows
    ({!Set_target_command_workflow},
    {!Commit_actual_fill_command_workflow},
    {!Reconcile_command_workflow},
    {!Define_alpha_view_command_workflow},
    {!Apply_bar_command_workflow}) — not the handlers — so the
    component boundary covered by these tests includes the
    outbound integration-event publication. The Hexagonal
    outbound ports [publish_*] are substituted with in-memory
    recorders.

    The construction → sizing → clipping pipeline ports
    ([risk_config_for], [total_equity_for], [mark_for],
    [volatility_for], [sizing_for]) are wired against in-memory
    registries; tests configure per-book risk configs, per-book
    equity, and per-book marks via [set_*] helpers before
    exercising the workflows. *)

module Pm = Portfolio_management
module DEH = Portfolio_management_domain_event_handlers
module Set_target_wf = Portfolio_management_commands.Set_target_command_workflow
module Set_target_h = Portfolio_management_commands.Set_target_command_handler

module Commit_actual_fill_wf =
  Portfolio_management_commands.Commit_actual_fill_command_workflow

module Commit_actual_fill_h =
  Portfolio_management_commands.Commit_actual_fill_command_handler

module Reconcile_wf = Portfolio_management_commands.Reconcile_command_workflow
module Reconcile_h = Portfolio_management_commands.Reconcile_command_handler
module Define_alpha_view_wf =
  Portfolio_management_commands.Define_alpha_view_command_workflow

module Define_alpha_view_h =
  Portfolio_management_commands.Define_alpha_view_command_handler

module Apply_bar_wf = Portfolio_management_commands.Apply_bar_command_workflow
module Apply_bar_h = Portfolio_management_commands.Apply_bar_command_handler

module Target_portfolio_updated_ie =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

module Trade_intents_planned_ie =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

let book_alpha_str = "alpha"
let book_alpha = Pm.Common.Book_id.of_string book_alpha_str

type ctx = {
  target_portfolio : Pm.Target_portfolio.t ref;
  actual_portfolio : Pm.Actual_portfolio.t ref;
  alpha_views : (string * string, Pm.Alpha_view.t ref) Hashtbl.t;
  subscriptions : (string * string, Pm.Common.Book_id.t list) Hashtbl.t;
  risk_configs : (string, Pm.Risk_config.t) Hashtbl.t;
  total_equities : (string, Decimal.t) Hashtbl.t;
  marks : (string, Decimal.t) Hashtbl.t;
      (** Keyed by [Instrument.to_qualified]; per-instrument, not
          per-book (matches production: a market price is a property
          of the instrument, not of the holder). *)
  target_portfolio_updated_pub : Target_portfolio_updated_ie.t list ref;
  trade_intents_planned_pub : Trade_intents_planned_ie.t list ref;
  last_set_target_result : (unit, Set_target_h.handle_error) Rop.t option;
  last_commit_actual_fill_result : (unit, Commit_actual_fill_h.handle_error) Rop.t option;
  last_reconcile_result : (unit, Reconcile_h.handle_error) Rop.t option;
  last_define_alpha_view_result : (unit, Define_alpha_view_h.handle_error) Rop.t option;
  last_apply_bar_result : (unit, Apply_bar_h.handle_error) Rop.t option;
}

let fresh_ctx () =
  {
    target_portfolio = ref (Pm.Target_portfolio.empty book_alpha);
    actual_portfolio = ref (Pm.Actual_portfolio.empty book_alpha);
    alpha_views = Hashtbl.create 4;
    subscriptions = Hashtbl.create 4;
    risk_configs = Hashtbl.create 4;
    total_equities = Hashtbl.create 4;
    marks = Hashtbl.create 16;
    target_portfolio_updated_pub = ref [];
    trade_intents_planned_pub = ref [];
    last_set_target_result = None;
    last_commit_actual_fill_result = None;
    last_reconcile_result = None;
    last_define_alpha_view_result = None;
    last_apply_bar_result = None;
  }

let actual_portfolio_for ctx book =
  if Pm.Common.Book_id.equal book book_alpha then Some ctx.actual_portfolio else None

let target_portfolio_for ctx book =
  if Pm.Common.Book_id.equal book book_alpha then Some !(ctx.target_portfolio) else None

let actual_portfolio_value_for ctx book =
  if Pm.Common.Book_id.equal book book_alpha then Some !(ctx.actual_portfolio) else None

let set_target ctx ~source ~proposed_at ~positions =
  let cmd : Portfolio_management_commands.Set_target_command.t =
    { book_id = book_alpha_str; source; proposed_at; positions }
  in
  let publish_target_portfolio_updated e =
    ctx.target_portfolio_updated_pub := e :: !(ctx.target_portfolio_updated_pub)
  in
  let result =
    Set_target_wf.execute ~target_portfolio:ctx.target_portfolio
      ~publish_target_portfolio_updated cmd
  in
  { ctx with last_set_target_result = Some result }

let commit_actual_fill
    ctx
    ~instrument
    ~new_position_quantity
    ~new_avg_price
    ~new_cash
    ~occurred_at =
  let cmd : Portfolio_management_commands.Commit_actual_fill_command.t =
    {
      book_id = book_alpha_str;
      instrument;
      new_position_quantity;
      new_avg_price;
      new_cash;
      occurred_at;
    }
  in
  let result =
    Commit_actual_fill_wf.execute ~actual_portfolio_for:(actual_portfolio_for ctx) cmd
  in
  { ctx with last_commit_actual_fill_result = Some result }

let subscribe ctx ~alpha_source_id ~instrument ~book_id =
  let key = (alpha_source_id, instrument) in
  let existing = try Hashtbl.find ctx.subscriptions key with Not_found -> [] in
  Hashtbl.replace ctx.subscriptions key (book_id :: existing);
  ctx

let default_limits () =
  Pm.Risk.Values.Risk_limits.make
    ~max_per_instrument_notional:(Decimal.of_int 1_000_000_000)
    ~max_gross_exposure:(Decimal.of_int 1_000_000_000)

let set_risk_config ctx ~book_id ~risk_budget_fraction ~construction_source =
  let cfg =
    Pm.Risk_config.make ~book_id ~risk_budget_fraction
      ~limits:(default_limits ()) ~construction_source
  in
  Hashtbl.replace ctx.risk_configs (Pm.Common.Book_id.to_string book_id) cfg;
  ctx

let set_total_equity ctx ~book_id ~equity =
  Hashtbl.replace ctx.total_equities (Pm.Common.Book_id.to_string book_id) equity;
  ctx

let set_mark ctx ~book_id:_ ~instrument ~price =
  Hashtbl.replace ctx.marks (Core.Instrument.to_qualified instrument) price;
  ctx

let risk_config_for ctx book =
  Hashtbl.find_opt ctx.risk_configs (Pm.Common.Book_id.to_string book)

let total_equity_for ctx book =
  match Hashtbl.find_opt ctx.total_equities (Pm.Common.Book_id.to_string book) with
  | Some d -> d
  | None -> Decimal.zero

let mark_for ctx _book instrument =
  match
    Hashtbl.find_opt ctx.marks (Core.Instrument.to_qualified instrument)
  with
  | Some p -> p
  | None -> Decimal.zero

let volatility_for _instrument = None

let sizing_for _book_id : DEH.Build_target_on_construction_intent.sizing_fn =
  fun ~book_equity ~mark ~volatility intent ->
    Pm.Sizing_policy.Equity_proportional.size () ~book_equity ~mark ~volatility intent

let define_alpha_view
    ctx
    ~alpha_source_id
    ~instrument
    ~direction
    ~strength
    ~price
    ~occurred_at =
  let alpha_view_for ~alpha_source_id:asid ~instrument:i =
    let key =
      (Pm.Common.Alpha_source_id.to_string asid, Core.Instrument.to_qualified i)
    in
    match Hashtbl.find_opt ctx.alpha_views key with
    | Some r -> r
    | None ->
        let r = ref (Pm.Alpha_view.empty ~alpha_source_id:asid ~instrument:i) in
        Hashtbl.add ctx.alpha_views key r;
        r
  in
  let subscribers_for ~alpha_source_id:asid ~instrument:i =
    let key =
      (Pm.Common.Alpha_source_id.to_string asid, Core.Instrument.to_qualified i)
    in
    try Hashtbl.find ctx.subscriptions key with Not_found -> []
  in
  let target_portfolio_for book =
    if Pm.Common.Book_id.equal book book_alpha then ctx.target_portfolio
    else
      (* For tests using extra books — auto-create empty target_portfolio. *)
      ref (Pm.Target_portfolio.empty book)
  in
  let publish_target_portfolio_updated e =
    ctx.target_portfolio_updated_pub := e :: !(ctx.target_portfolio_updated_pub)
  in
  let cmd : Portfolio_management_commands.Define_alpha_view_command.t =
    { alpha_source_id; instrument; direction; strength; price; occurred_at }
  in
  let result =
    Define_alpha_view_wf.execute ~alpha_view_for ~subscribers_for
      ~risk_config_for:(risk_config_for ctx)
      ~total_equity_for:(total_equity_for ctx)
      ~mark_for:(mark_for ctx) ~volatility_for ~sizing_for
      ~target_portfolio_for ~publish_target_portfolio_updated cmd
  in
  { ctx with last_define_alpha_view_result = Some result }

(** Drive an {!Apply_bar_command_workflow} call against the
    supplied pair_mr [state_ref]. The state ref is mutated in
    place; on success any emitted construction_intent is fed
    into the unified pipeline against [ctx]'s registries and
    publishes a [target_portfolio_updated] event. The bar is
    built with [open=high=low=close] for convenience —
    sufficient for component-level driver tests. *)
let apply_bar ctx ~state_ref ~instrument ~ts ~close =
  let pair_mr_states_for inst =
    let cfg = Pm.Pair_mean_reversion.Values.Pair_mr_state.config !state_ref in
    if Pm.Common.Pair.contains cfg.pair inst then [ state_ref ] else []
  in
  let target_portfolio_for book =
    if Pm.Common.Book_id.equal book book_alpha then ctx.target_portfolio
    else ref (Pm.Target_portfolio.empty book)
  in
  let publish_target_portfolio_updated e =
    ctx.target_portfolio_updated_pub := e :: !(ctx.target_portfolio_updated_pub)
  in
  let close_str = Decimal.to_string close in
  let candle : Portfolio_management_commands.Apply_bar_command.candle_dto =
    {
      ts = Datetime.Iso8601.format ts;
      open_ = close_str;
      high = close_str;
      low = close_str;
      close = close_str;
      volume = Decimal.to_string Decimal.one;
    }
  in
  let cmd : Portfolio_management_commands.Apply_bar_command.t =
    { instrument = Core.Instrument.to_qualified instrument; timeframe = "h1"; candle }
  in
  let update_mark inst ~close =
    Hashtbl.replace ctx.marks (Core.Instrument.to_qualified inst) close
  in
  let result =
    Apply_bar_wf.execute ~pair_mr_states_for ~update_mark
      ~risk_config_for:(risk_config_for ctx)
      ~total_equity_for:(total_equity_for ctx)
      ~mark_for:(mark_for ctx) ~volatility_for ~sizing_for
      ~target_portfolio_for ~publish_target_portfolio_updated cmd
  in
  { ctx with last_apply_bar_result = Some result }

let reconcile ctx ~computed_at =
  let cmd : Portfolio_management_commands.Reconcile_command.t =
    { book_id = book_alpha_str; computed_at }
  in
  let publish_trade_intents_planned e =
    ctx.trade_intents_planned_pub := e :: !(ctx.trade_intents_planned_pub)
  in
  let result =
    Reconcile_wf.execute ~target_portfolio_for:(target_portfolio_for ctx)
      ~actual_portfolio_for:(actual_portfolio_value_for ctx)
      ~publish_trade_intents_planned cmd
  in
  { ctx with last_reconcile_result = Some result }

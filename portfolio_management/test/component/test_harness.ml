(** In-process test harness for the Portfolio Management BC.

    Drives the application-layer workflows ({!Set_target_command_workflow},
    {!Change_position_command_workflow},
    {!Change_cash_command_workflow},
    {!Reconcile_command_workflow}) — not the handlers — so the component
    boundary covered by these tests includes the outbound integration-
    event projection. The Hexagonal outbound ports [publish_*] are
    substituted with in-memory recorders. *)

module Pm = Portfolio_management
module Set_target_wf = Portfolio_management_commands.Set_target_command_workflow
module Set_target_h = Portfolio_management_commands.Set_target_command_handler

module Change_position_wf = Portfolio_management_commands.Change_position_command_workflow

module Change_position_h = Portfolio_management_commands.Change_position_command_handler

module Change_cash_wf = Portfolio_management_commands.Change_cash_command_workflow

module Change_cash_h = Portfolio_management_commands.Change_cash_command_handler

module Reconcile_wf = Portfolio_management_commands.Reconcile_command_workflow
module Reconcile_h = Portfolio_management_commands.Reconcile_command_handler
module Define_alpha_view_wf =
  Portfolio_management_commands.Define_alpha_view_command_workflow

module Define_alpha_view_h =
  Portfolio_management_commands.Define_alpha_view_command_handler

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
  notional_caps : (string, Decimal.t) Hashtbl.t;
  target_portfolio_updated_pub : Target_portfolio_updated_ie.t list ref;
  trade_intents_planned_pub : Trade_intents_planned_ie.t list ref;
  last_set_target_result : (unit, Set_target_h.handle_error) Rop.t option;
  last_change_position_result : (unit, Change_position_h.handle_error) Rop.t option;
  last_change_cash_result : (unit, Change_cash_h.handle_error) Rop.t option;
  last_reconcile_result : (unit, Reconcile_h.handle_error) Rop.t option;
  last_define_alpha_view_result : (unit, Define_alpha_view_h.handle_error) Rop.t option;
}

let fresh_ctx () =
  {
    target_portfolio = ref (Pm.Target_portfolio.empty book_alpha);
    actual_portfolio = ref (Pm.Actual_portfolio.empty book_alpha);
    alpha_views = Hashtbl.create 4;
    subscriptions = Hashtbl.create 4;
    notional_caps = Hashtbl.create 4;
    target_portfolio_updated_pub = ref [];
    trade_intents_planned_pub = ref [];
    last_set_target_result = None;
    last_change_position_result = None;
    last_change_cash_result = None;
    last_reconcile_result = None;
    last_define_alpha_view_result = None;
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

let change_position ctx ~instrument ~delta_qty ~new_qty ~avg_price ~occurred_at =
  let cmd : Portfolio_management_commands.Change_position_command.t =
    { book_id = book_alpha_str; instrument; delta_qty; new_qty; avg_price; occurred_at }
  in
  let result =
    Change_position_wf.execute ~actual_portfolio_for:(actual_portfolio_for ctx) cmd
  in
  { ctx with last_change_position_result = Some result }

let change_cash ctx ~delta ~new_balance ~occurred_at =
  let cmd : Portfolio_management_commands.Change_cash_command.t =
    { book_id = book_alpha_str; delta; new_balance; occurred_at }
  in
  let result =
    Change_cash_wf.execute ~actual_portfolio_for:(actual_portfolio_for ctx) cmd
  in
  { ctx with last_change_cash_result = Some result }

let subscribe ctx ~alpha_source_id ~instrument ~book_id =
  let key = (alpha_source_id, instrument) in
  let existing = try Hashtbl.find ctx.subscriptions key with Not_found -> [] in
  Hashtbl.replace ctx.subscriptions key (book_id :: existing);
  ctx

let set_notional_cap ctx ~book_id ~cap =
  Hashtbl.replace ctx.notional_caps (Pm.Common.Book_id.to_string book_id) cap;
  ctx

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
  let notional_cap_for book =
    match Hashtbl.find_opt ctx.notional_caps (Pm.Common.Book_id.to_string book) with
    | Some d -> d
    | None -> Decimal.zero
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
    Define_alpha_view_wf.execute ~alpha_view_for ~subscribers_for ~notional_cap_for
      ~target_portfolio_for ~publish_target_portfolio_updated cmd
  in
  { ctx with last_define_alpha_view_result = Some result }

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

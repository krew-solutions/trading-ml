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

module Target_portfolio_updated_ie =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

module Trade_intents_planned_ie =
  Portfolio_management_integration_events.Trade_intents_planned_integration_event

let book_alpha_str = "alpha"
let book_alpha = Pm.Shared.Book_id.of_string book_alpha_str

type ctx = {
  target_portfolio : Pm.Target_portfolio.t ref;
  actual_portfolio : Pm.Actual_portfolio.t ref;
  target_portfolio_updated_pub : Target_portfolio_updated_ie.t list ref;
  trade_intents_planned_pub : Trade_intents_planned_ie.t list ref;
  last_set_target_result : (unit, Set_target_h.handle_error) Rop.t option;
  last_change_position_result : (unit, Change_position_h.handle_error) Rop.t option;
  last_change_cash_result : (unit, Change_cash_h.handle_error) Rop.t option;
  last_reconcile_result : (unit, Reconcile_h.handle_error) Rop.t option;
}

let fresh_ctx () =
  {
    target_portfolio = ref (Pm.Target_portfolio.empty book_alpha);
    actual_portfolio = ref (Pm.Actual_portfolio.empty book_alpha);
    target_portfolio_updated_pub = ref [];
    trade_intents_planned_pub = ref [];
    last_set_target_result = None;
    last_change_position_result = None;
    last_change_cash_result = None;
    last_reconcile_result = None;
  }

let actual_portfolio_for ctx book =
  if Pm.Shared.Book_id.equal book book_alpha then Some ctx.actual_portfolio else None

let target_portfolio_for ctx book =
  if Pm.Shared.Book_id.equal book book_alpha then Some !(ctx.target_portfolio) else None

let actual_portfolio_value_for ctx book =
  if Pm.Shared.Book_id.equal book book_alpha then Some !(ctx.actual_portfolio) else None

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

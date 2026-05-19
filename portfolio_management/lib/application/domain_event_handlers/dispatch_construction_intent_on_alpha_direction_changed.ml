module Pm = Portfolio_management
module Direction_changed = Pm.Alpha_view.Events.Direction_changed

module Target_portfolio_updated =
  Portfolio_management_integration_events.Target_portfolio_updated_integration_event

let handle
    ~subscribers_for
    ~risk_config_for
    ~total_equity_for
    ~mark_for
    ~volatility_for
    ~sizing_for
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    (event : Direction_changed.t) : unit =
  let books =
    subscribers_for ~alpha_source_id:event.alpha_source_id
      ~instrument:event.instrument
  in
  List.iter
    (fun (book_id : Pm.Common.Book_id.t) ->
      let intent = Direction_changed.to_construction_intent event ~book_id in
      Build_target_on_construction_intent.handle ~risk_config_for
        ~total_equity_for ~mark_for ~volatility_for ~sizing_for
        ~target_portfolio_for ~publish_target_portfolio_updated intent)
    books

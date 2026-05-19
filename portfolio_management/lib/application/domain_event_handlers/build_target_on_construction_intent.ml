module Risk_config = Portfolio_management.Risk_config
module Common = Portfolio_management.Common
module Target_portfolio = Portfolio_management.Target_portfolio
module Risk = Portfolio_management.Risk

type sizing_fn =
  book_equity:Decimal.t ->
  mark:(Core.Instrument.t -> Decimal.t) ->
  volatility:(Core.Instrument.t -> Decimal.t option) ->
  Common.Construction_intent.t ->
  Common.Target_proposal.t

let handle
    ~risk_config_for
    ~total_equity_for
    ~mark_for
    ~volatility_for
    ~sizing_for
    ~target_portfolio_for
    ~publish_target_portfolio_updated
    (intent : Common.Construction_intent.t) : unit =
  let book_id = Common.Construction_intent.book_id intent in
  match risk_config_for book_id with
  | None ->
      (* Defensive: a book emitting intents without a Risk_config
         is a wiring inconsistency. Silent skip — composition is
         responsible for keeping registries aligned. *)
      ()
  | Some risk_cfg ->
      let source = Common.Construction_intent.source intent in
      if not (Risk_config.authorises risk_cfg source) then
        (* One-source-per-book invariant: silently drop intents
           whose source does not match the book's configured
           construction_source. *)
        ()
      else
        let total_equity = total_equity_for book_id in
        let book_equity =
          Risk_config.book_equity risk_cfg ~total_equity
        in
        let mark = mark_for book_id in
        let size = sizing_for book_id in
        let proposal =
          size ~book_equity ~mark ~volatility:volatility_for intent
        in
        let clipped =
          Risk.Risk_policy.clip
            ~limits:(Risk_config.limits risk_cfg)
            ~mark proposal
        in
        let r = target_portfolio_for book_id in
        (match Target_portfolio.apply_proposal !r clipped with
        | Ok (t', target_set) ->
            r := t';
            Publish_integration_event_on_target_set.handle
              ~publish_target_portfolio_updated target_set
        | Error _ -> ())

(** Compile-time checks that every [*_view_model] in this library
    implements {!View_model.S}. Mirrors the equivalent in
    [account_queries]. *)

module _ :
  View_model.S
    with type t = Instrument_view_model.t
     and type domain = Instrument_view_model.domain =
  Instrument_view_model

module _ :
  View_model.S
    with type t = Target_position_view_model.t
     and type domain = Target_position_view_model.domain =
  Target_position_view_model

module _ :
  View_model.S
    with type t = Target_portfolio_view_model.t
     and type domain = Target_portfolio_view_model.domain =
  Target_portfolio_view_model

module _ :
  View_model.S
    with type t = Actual_position_view_model.t
     and type domain = Actual_position_view_model.domain =
  Actual_position_view_model

module _ :
  View_model.S
    with type t = Actual_portfolio_view_model.t
     and type domain = Actual_portfolio_view_model.domain =
  Actual_portfolio_view_model

module _ :
  View_model.S
    with type t = Trade_intent_view_model.t
     and type domain = Trade_intent_view_model.domain =
  Trade_intent_view_model

(** Compile-time checks that every [*_view_model] in this
    library implements {!View_model.S}. Any divergence — missing
    [of_domain], wrong signature, renamed [yojson_of_t], etc. —
    fails the build here with a clear error.

    No runtime cost: every [module _ :] binding is erased after
    type-checking. *)

module _ :
  View_model.S
    with type t = Candle_view_model.t
     and type domain = Candle_view_model.domain =
  Candle_view_model

module _ :
  View_model.S
    with type t = Instrument_view_model.t
     and type domain = Instrument_view_model.domain =
  Instrument_view_model

module _ :
  View_model.S
    with type t = Order_kind_view_model.t
     and type domain = Order_kind_view_model.domain =
  Order_kind_view_model

module _ :
  View_model.S
    with type t = Signal_view_model.t
     and type domain = Signal_view_model.domain =
  Signal_view_model

module _ :
  View_model.S with type t = Order_view_model.t and type domain = Order_view_model.domain =
  Order_view_model

module _ :
  View_model.S
    with type t = Position_view_model.t
     and type domain = Position_view_model.domain =
  Position_view_model

module _ :
  View_model.S
    with type t = Reservation_view_model.t
     and type domain = Reservation_view_model.domain =
  Reservation_view_model

module _ :
  View_model.S
    with type t = Portfolio_view_model.t
     and type domain = Portfolio_view_model.domain =
  Portfolio_view_model

module _ :
  View_model.S with type t = Fill_view_model.t and type domain = Fill_view_model.domain =
  Fill_view_model

module _ :
  View_model.S
    with type t = Backtest_result_view_model.t
     and type domain = Backtest_result_view_model.domain =
  Backtest_result_view_model

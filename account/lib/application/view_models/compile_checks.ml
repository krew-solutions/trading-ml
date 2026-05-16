(** Compile-time checks that every [*_view_model] in this
    library implements {!View_model.S}. Any divergence — missing
    [of_domain], wrong signature, renamed [yojson_of_t], etc. —
    fails the build here with a clear error.

    No runtime cost: every [module _ :] binding is erased after
    type-checking. *)

module _ :
  View_model.S
    with type t = Instrument_view_model.t
     and type domain = Instrument_view_model.domain =
  Instrument_view_model

module _ :
  View_model.S
    with type t = Portfolio_view_model.t
     and type domain = Portfolio_view_model.domain =
  Portfolio_view_model

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

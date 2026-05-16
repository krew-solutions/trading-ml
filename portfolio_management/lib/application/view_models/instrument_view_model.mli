(** Read-model DTO for {!Core.Instrument.t}.

    Local copy of the same VM in the strategy / account BCs: kept
    independent so that [portfolio_management_view_models] doesn't depend
    on the other BCs and the BC graph stays acyclic. The on-wire JSON
    shape is identical between the three.

    The wire shape is generated from
    [shared/contracts/portfolio_management/view_models/instrument_view_model.atd]
    via atdgen. *)

include module type of Instrument_view_model_t

include module type of Instrument_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Core.Instrument.t

val of_domain : domain -> t

(** Read-model DTO for
    {!Portfolio_management.Actual_portfolio.Values.Actual_position.t}.

    The wire shape is generated from
    [shared/contracts/portfolio_management/view_models/actual_position_view_model.atd]
    via atdgen. *)

include module type of Actual_position_view_model_t

include module type of Actual_position_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Portfolio_management.Actual_portfolio.Values.Actual_position.t

val of_domain : domain -> t

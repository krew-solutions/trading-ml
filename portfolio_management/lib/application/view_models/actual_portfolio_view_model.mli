(** Read-model DTO for {!Portfolio_management.Actual_portfolio.t}.

    The wire shape is generated from
    [shared/contracts/portfolio_management/view_models/actual_portfolio_view_model.atd]
    via atdgen. *)

include module type of Actual_portfolio_view_model_t

include module type of Actual_portfolio_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Portfolio_management.Actual_portfolio.t

val of_domain : domain -> t

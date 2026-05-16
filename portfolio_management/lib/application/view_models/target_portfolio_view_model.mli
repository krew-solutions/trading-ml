(** Read-model DTO for {!Portfolio_management.Target_portfolio.t}. *)

type t = { book_id : string; positions : Target_position_view_model.t list }
[@@deriving yojson]

type domain = Portfolio_management.Target_portfolio.t

val of_domain : domain -> t

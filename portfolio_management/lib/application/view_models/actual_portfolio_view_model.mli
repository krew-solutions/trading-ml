(** Read-model DTO for {!Portfolio_management.Actual_portfolio.t}. *)

type t = {
  book_id : string;
  cash : string;  (** signed Decimal string; can be negative under margin *)
  positions : Actual_position_view_model.t list;
}
[@@deriving yojson]

type domain = Portfolio_management.Actual_portfolio.t

val of_domain : domain -> t

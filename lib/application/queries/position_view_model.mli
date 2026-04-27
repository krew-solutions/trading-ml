(** Read-model DTO for {!Account.Portfolio.position}. *)

type t = { instrument : Instrument_view_model.t; quantity : float; avg_price : float }
[@@deriving yojson]

type domain = Account.Portfolio.position

val of_domain : domain -> t

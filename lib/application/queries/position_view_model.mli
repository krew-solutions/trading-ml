(** Read-model DTO for {!Account.Portfolio.Values.Position.t}. *)

type t = { instrument : Instrument_view_model.t; quantity : float; avg_price : float }
[@@deriving yojson]

type domain = Account.Portfolio.Values.Position.t

val of_domain : domain -> t

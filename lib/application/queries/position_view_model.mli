(** Read-model DTO for {!Engine.Portfolio.position}. *)

type t = { instrument : Instrument_view_model.t; quantity : float; avg_price : float }
[@@deriving yojson]

type domain = Engine.Portfolio.position

val of_domain : domain -> t

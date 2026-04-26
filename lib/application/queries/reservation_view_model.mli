(** Read-model DTO for {!Engine.Portfolio.reservation}. *)

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  quantity : float;
  per_unit_cash : float;
}
[@@deriving yojson]

type domain = Engine.Portfolio.reservation

val of_domain : domain -> t

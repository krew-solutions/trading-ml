(** Read-model DTO for {!Account.Portfolio.reservation}. *)

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  quantity : float;
  per_unit_cash : float;
}
[@@deriving yojson]

type domain = Account.Portfolio.reservation

val of_domain : domain -> t

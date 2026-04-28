(** Read-model DTO for {!Account.Portfolio.Reservation.t}. *)

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  quantity : float;
  per_unit_cash : float;
}
[@@deriving yojson]

type domain = Account.Portfolio.Reservation.t

val of_domain : domain -> t

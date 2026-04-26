(** Outbound projection of {!Engine.Portfolio.amount_reserved}. *)

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : float;
  price : float;
  reserved_cash : float;
}
[@@deriving yojson]

type domain = Engine.Portfolio.amount_reserved

val of_domain : domain -> t

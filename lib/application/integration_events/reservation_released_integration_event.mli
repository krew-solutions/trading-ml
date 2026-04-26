(** Outbound projection of {!Engine.Portfolio.reservation_released}. *)

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
}
[@@deriving yojson]

type domain = Engine.Portfolio.reservation_released

val of_domain : domain -> t

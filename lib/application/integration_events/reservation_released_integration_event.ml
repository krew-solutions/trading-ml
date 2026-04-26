open Core

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
}
[@@deriving yojson]

type domain = Engine.Portfolio.reservation_released

let of_domain (ev : domain) : t =
  {
    reservation_id = ev.reservation_id;
    side = Side.to_string ev.side;
    instrument = Queries.Instrument_view_model.of_domain ev.instrument;
  }

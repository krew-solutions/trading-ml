(** Read-model DTO for {!Engine.Portfolio.t}.

    Positions are projected as a flat list. The domain stores
    them keyed by instrument for O(log n) lookup, but the
    instrument identity is inside each entry, so the list form
    loses nothing across the wire. *)

type t = {
  cash : float;
  realized_pnl : float;
  positions : Position_view_model.t list;
  reservations : Reservation_view_model.t list;
}
[@@deriving yojson]

type domain = Engine.Portfolio.t

val of_domain : domain -> t

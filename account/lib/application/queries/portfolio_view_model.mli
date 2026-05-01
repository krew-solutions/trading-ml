(** Read-model DTO for {!Account.Portfolio.t}.

    Positions are projected as a flat list. The domain stores
    them keyed by instrument for O(log n) lookup, but the
    instrument identity is inside each entry, so the list form
    loses nothing across the wire. *)

type t = {
  cash : string;  (** Decimal string accepted by {!Decimal.of_string}. *)
  realized_pnl : string;
  positions : Position_view_model.t list;
  reservations : Reservation_view_model.t list;
}
[@@deriving yojson]

type domain = Account.Portfolio.t

val of_domain : domain -> t

(** Read-model DTO for {!Account.Portfolio.Reservation.t}. *)

type t = {
  id : int;
  side : string;
  instrument : Instrument_view_model.t;
  cover_qty : string;
      (** Decimal string accepted by {!Decimal.of_string}. Closes the
          opposite-side existing position. *)
  open_qty : string;  (** Opens or grows the same-side position. *)
  per_unit_collateral : string;  (** Per-unit cash blocked on the open portion. *)
}
[@@deriving yojson]

type domain = Account.Portfolio.Reservation.t

val of_domain : domain -> t

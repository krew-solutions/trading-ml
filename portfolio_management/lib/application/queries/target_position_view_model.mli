(** Read-model DTO for {!Portfolio_management.Shared.Target_position.t}. *)

type t = {
  book_id : string;
  instrument : Instrument_view_model.t;
  target_qty : string;  (** signed Decimal string *)
}
[@@deriving yojson]

type domain = Portfolio_management.Shared.Target_position.t

val of_domain : domain -> t

(** Read-model DTO for {!Portfolio_management.Shared.Trade_intent.t}. *)

type t = {
  book_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;  (** Decimal string; strictly positive *)
}
[@@deriving yojson]

type domain = Portfolio_management.Shared.Trade_intent.t

val of_domain : domain -> t

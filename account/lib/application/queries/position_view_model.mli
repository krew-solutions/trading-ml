(** Read-model DTO for {!Account.Portfolio.Values.Position.t}. *)

type t = {
  instrument : Instrument_view_model.t;
  quantity : string;  (** Decimal string accepted by {!Core.Decimal.of_string}. *)
  avg_price : string;
}
[@@deriving yojson]

type domain = Account.Portfolio.Values.Position.t

val of_domain : domain -> t

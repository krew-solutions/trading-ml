(** Read-model DTO for
    {!Portfolio_management.Actual_portfolio.Values.Actual_position.t}. *)

type t = {
  instrument : Instrument_view_model.t;
  quantity : string;  (** signed Decimal string *)
  avg_price : string;
}
[@@deriving yojson]

type domain = Portfolio_management.Actual_portfolio.Values.Actual_position.t

val of_domain : domain -> t

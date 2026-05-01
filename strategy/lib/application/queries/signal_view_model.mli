(** Read-model DTO for {!Core.Signal.t}. *)

type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  action : string;
  strength : float;
      (** Domain float — strategy confidence in [0.0; 1.0], not a Decimal-derived value. *)
  stop_loss : string option;  (** Decimal string accepted by {!Decimal.of_string}. *)
  take_profit : string option;
  reason : string;
}
[@@deriving yojson]

type domain = Core.Signal.t

val of_domain : domain -> t

(** Read-model DTO for {!Core.Signal.t}. *)

type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  action : string;
  strength : float;
  stop_loss : float option;
  take_profit : float option;
  reason : string;
}
[@@deriving yojson]

type domain = Core.Signal.t

val of_domain : domain -> t

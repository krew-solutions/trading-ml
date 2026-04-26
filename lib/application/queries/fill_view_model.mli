(** Read-model DTO for {!Engine.Backtest.fill}. *)

type t = {
  ts : int64;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : float;
  price : float;
  fee : float;
  reason : string;
}
[@@deriving yojson]

type domain = Engine.Backtest.fill

val of_domain : domain -> t

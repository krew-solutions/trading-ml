(** Strategy output: an intent for the engine to translate into orders. *)

type action = Enter_long | Enter_short | Exit_long | Exit_short | Hold

type t = {
  ts : int64;
  instrument : Instrument.t;
  action : action;
  strength : float;
  stop_loss : Decimal.t option;
  take_profit : Decimal.t option;
  reason : string;
}

val hold : ts:int64 -> instrument:Instrument.t -> t
val action_to_string : action -> string

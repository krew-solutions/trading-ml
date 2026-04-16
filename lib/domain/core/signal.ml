(** Strategy output: an intent for the engine to translate into orders. *)

type action =
  | Enter_long
  | Enter_short
  | Exit_long
  | Exit_short
  | Hold

type t = {
  ts : int64;
  symbol : Symbol.t;
  action : action;
  strength : float;       (** in [0.0; 1.0], for position sizing *)
  stop_loss : Decimal.t option;
  take_profit : Decimal.t option;
  reason : string;
}

let hold ~ts ~symbol = {
  ts; symbol; action = Hold; strength = 0.; stop_loss = None;
  take_profit = None; reason = "";
}

let action_to_string = function
  | Enter_long -> "ENTER_LONG" | Enter_short -> "ENTER_SHORT"
  | Exit_long -> "EXIT_LONG" | Exit_short -> "EXIT_SHORT"
  | Hold -> "HOLD"

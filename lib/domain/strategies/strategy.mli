(** Strategy signature: stream candles in, emit Signal.t decisions out.
    Strategies are explicit state machines with no global mutable state, so
    they are trivially deterministic -- identical inputs always yield
    identical outputs. This is a property we rely on for backtesting and
    formal reasoning. *)

open Core

(** Module type that every strategy must implement. *)
module type S = sig
  type state
  type params

  val name : string
  val default_params : params
  val init : params -> state

  val on_candle :
    state -> Instrument.t -> Candle.t -> state * Signal.t
end

(** Existential wrapper hiding the concrete state/params types. *)
type t

(** [make (module M) params] creates a strategy instance with explicit params. *)
val make :
  (module S with type state = 's and type params = 'p) -> 'p -> t

(** [default (module M)] creates a strategy instance using [M.default_params]. *)
val default :
  (module S with type state = 's and type params = 'p) -> t

(** Feed one candle; returns the updated strategy and the resulting signal. *)
val on_candle : t -> Instrument.t -> Candle.t -> t * Signal.t

(** Human-readable name of the underlying strategy module. *)
val name : t -> string

(** Composite strategy: combines N child strategies under a voting
    policy. Implements [Strategy.S] so it's indistinguishable from a
    leaf — can be backtested, registered, or nested. *)

open Core

type policy =
  | Unanimous   (** all non-Hold children must agree *)
  | Majority    (** >50% of non-Hold children *)
  | Any         (** at least one child *)

type params = {
  policy : policy;
  children : Strategy.t list;
}

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t

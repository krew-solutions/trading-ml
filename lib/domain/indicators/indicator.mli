(** Incremental streaming indicator: each indicator is a first-class value
    implementing {!S}. The engine folds candles through it and reads the
    current output without recomputing history. *)

open Core

module type S = sig
  type state
  type output

  val name : string
  val init : unit -> state
  val update : state -> Candle.t -> state * output option
  val value : state -> output option

  val output_to_float : output -> float list
  (** Flattened numeric output -- used by the server/UI. For scalar
      indicators, a single-element list; for MACD, three; for Bollinger,
      three; and so on. *)
end

type t
(** Existential wrapper: heterogeneous indicators live in a single list. *)

val make : (module S with type state = 's and type output = 'o) -> t
val update : t -> Candle.t -> t
val value : t -> (string * float list) option
val name : t -> string

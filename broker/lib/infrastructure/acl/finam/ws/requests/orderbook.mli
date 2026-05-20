(** WS request encoders for the ORDER_BOOK channel. *)

open Core

val subscribe : token:string -> Instrument.t -> Yojson.Safe.t
val unsubscribe : token:string -> Instrument.t -> Yojson.Safe.t

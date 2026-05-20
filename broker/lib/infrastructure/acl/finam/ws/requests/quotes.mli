(** WS request encoders for the QUOTES channel.

    SUBSCRIBE / UNSUBSCRIBE envelopes accept an instrument list
    (Finam allows multiplexed subscriptions on a single
    request). *)

open Core

val subscribe : token:string -> Instrument.t list -> Yojson.Safe.t
val unsubscribe : token:string -> Instrument.t list -> Yojson.Safe.t

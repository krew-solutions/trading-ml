(** Inbound [CandleStickSuccess] acknowledgement — confirms the
    server accepted a SUBSCRIBE (or UNSUBSCRIBE) request. *)

open Core

type t = {
  instrument : Instrument.t;
  timeframe : Timeframe.t;
  subscribe_type : int;  (** 0 — subscribe, 1 — unsubscribe *)
}

val parse : Yojson.Safe.t -> t

(** Inbound INSTRUMENT_TRADES event: a batch of public-tape prints for
    one instrument (all market participants), distinct from the account
    TRADES channel (own-order fills).

    The instrument is taken from the payload's [symbol] (falling back to
    the envelope [subscription_key]). [side] is [Some Buy]/[Some Sell]
    for the venue's aggressor, [None] for SIDE_UNSPECIFIED (auction /
    negotiated, no initiator). *)

open Core

type update = {
  side : Side.t option;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;
}

type t = { instrument : Instrument.t; trades : update list }

val parse : Yojson.Safe.t -> t
(** Parses the INSTRUMENT_TRADES payload from a full DATA envelope.
    Raises [Invalid_argument] when the symbol is absent — the WS
    bridge's decode-fail handler logs and drops the frame. *)

val to_domain : t -> Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t list
(** Fans the batch into one {!Remote_public_trade_updated} per print. *)

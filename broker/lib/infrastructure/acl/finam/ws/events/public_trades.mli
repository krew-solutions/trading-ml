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

val to_domain : t -> Broker_domain.Remote_broker.Events.Public_trade_printed.t list
(** Fans the batch into one {!Public_trade_printed} per print. *)

val update_to_domain :
  instrument:Instrument.t ->
  update ->
  Broker_domain.Remote_broker.Events.Public_trade_printed.t
(** Lift one print to a {!Public_trade_printed} for a known instrument —
    shared by {!to_domain} (WS tape) and the REST poller, which knows the
    instrument from its subscription rather than the payload. *)

val parse_rest_latest : Yojson.Safe.t -> (int64 option * update) list
(** Parse a REST [/trades/latest] response body into [(trade_id, print)]
    pairs. [trade_id] is Finam's monotonic per-instrument sequence number,
    the REST poller's high-water dedup key ([None] when absent / non-numeric;
    the [{"trade_id":"0"}] heartbeat stub is dropped by the shared print
    parser before reaching here). Distinct from {!parse}, which decodes the
    WS DATA envelope. *)

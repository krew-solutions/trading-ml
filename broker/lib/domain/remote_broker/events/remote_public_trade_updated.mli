(** Domain event — the venue printed a public trade on the tape for
    [instrument]. Recognised by the ACL adapter from the broker's wire
    frame (Finam INSTRUMENT_TRADES, BCS dataType:2, Alor AllTrades) and
    emitted into [Remote_broker.Events].

    Distinct from [Trade_executed], which reports fills of THIS account's
    own orders (carries [placement_id], ADR 0029). A public-tape print is
    venue data with no order linkage — every market participant's trade,
    used for order-flow / footprint analysis downstream.

    [side] is the venue-reported aggressor: [Some Buy] lifted the ask,
    [Some Sell] hit the bid, [None] for auction crosses and negotiated
    trades that have no initiator (Finam's [SIDE_UNSPECIFIED]). The
    BUY/SELL mapping rests on MOEX convention; ADR 0032 records the
    deferred empirical confirmation, and this adapter boundary is the
    single point to flip it if it proves inverted. *)

type t = {
  instrument : Core.Instrument.t;
  side : Core.Side.t option;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;  (** execution time, unix epoch seconds (UTC) *)
}

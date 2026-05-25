(** Per-trade record from [GET /v1/accounts/{account_id}/trades].
    Shape per the Finam REST docs
    (tradeapi.finam.ru/docs/rest/accountsservice_trades.md) and
    the canonical AccountTrade proto message:
    {v
    { "trade_id":   "...",
      "symbol":     "SBER@MISX",
      "price":      {"value": "..."},
      "size":       {"value": "..."},
      "side":       "SIDE_BUY" | "SIDE_SELL",
      "timestamp":  "2026-04-18T10:00:00Z",
      "order_id":   "...",
      "account_id": "...",
      "comment":    "..." }
    v}
    Finam's trade payload does not currently carry a per-trade
    fee field; we default to zero. If commission becomes needed
    for accurate reconcile P&L, fetch from the order state and
    prorate by fill quantity. [account_id] and [comment] are
    dropped — neither is consumed downstream and both would
    leak Finam concerns into the broker port. *)

type t = {
  order_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  trade : Broker_domain.Order.Trade.t;
}

val of_json : Yojson.Safe.t -> t
(** Decode one element of the [trades] array. Tolerant of
    missing/null per-element fields (defaults to empty
    strings and [Decimal.zero]). *)

val list_of_json : Yojson.Safe.t -> t list
(** Decode the full [accountsTradesResponse] payload, reading
    the top-level [trades] array. Returns [] if the array is
    missing or malformed. *)

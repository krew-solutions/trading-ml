(** A snapshot of top-of-book pricing — bid / ask plus the
    market's rolling realised-volatility estimate at that instant.
    Consumed by the Implementation Shortfall strategy to react to
    adverse price movement on the precomputed Almgren-Chriss
    trajectory. The market_data feed is a deferred infrastructure
    adapter today (the [Disabled] stub registers but never emits).

    Invariants:
    - [bid > 0], [ask > 0], [bid ≤ ask];
    - [realised_volatility ≥ 0]. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private {
  ts : int64;
  bid : Decimal.t;
  ask : Decimal.t;
  realised_volatility : float;
}

val make : ts:int64 -> bid:Decimal.t -> ask:Decimal.t -> realised_volatility:float -> t
(*@ r = make ~ts ~bid ~ask ~realised_volatility
    requires dec_raw bid > 0
    requires dec_raw ask > 0
    requires dec_raw bid <= dec_raw ask
    requires realised_volatility >= 0.0
    ensures r.ts = ts *)

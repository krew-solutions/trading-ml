(** A single aggregated volume observation from the market — one
    timeframe bucket's traded quantity. Consumed by the POV
    strategy to pace participation; the underlying volume feed is
    a deferred infrastructure adapter today (the [Disabled] stub
    registers but never emits), so POV is observably blocked
    rather than silently inert.

    Invariants:
    - [volume ≥ 0]. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private { ts : int64; volume : Decimal.t }

val make : ts:int64 -> volume:Decimal.t -> t
(*@ r = make ~ts ~volume
    requires dec_raw volume >= 0
    ensures r.ts = ts
    ensures dec_raw r.volume = dec_raw volume *)

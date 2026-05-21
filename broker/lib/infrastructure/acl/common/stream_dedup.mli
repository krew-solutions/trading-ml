(** Generic monotonic-stream deduplicator for inbound recognizers
    (per Vernon: the recognizer of external facts may need to
    suppress duplicate observations of the same fact).

    For each [key] the dedup tracks the highest [ts] seen so far
    (the {b tail}) and the set of {b distinct values} observed at
    exactly that tail. Filtering rules per inbound observation:

    - [ts < tail_ts]   stale snapshot — reject.
    - [ts > tail_ts]   new period — accept; reset the per-ts seen
                       set to [\[value\]], advance the tail.
    - [ts = tail_ts]   intra-period refresh — accept iff [value]
                       has not already been seen at this tail
                       (compared via the [equal_value] supplied
                       at [create] time).

    Use case: bar-feed dedup in broker adapters (key =
    [(Instrument.t, Timeframe.t)], value = [Candle.t]). The same
    pattern applies to any inbound stream subject to WS replay /
    reconnect / late snapshots. *)

type ('key, 'value) t

val create : equal_value:('value -> 'value -> bool) -> ('key, 'value) t

val should_accept : ('key, 'value) t -> key:'key -> ts:int64 -> value:'value -> bool

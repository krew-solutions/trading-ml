(** Bus publisher for {!Broker_integration_events.Bar_updated_integration_event}.
    Sole entry point for emitting on the [broker.bar-updated] topic;
    no other code in the broker BC should reach into [Bus.publish]
    for this URI directly.

    The publisher is stateful: it owns the per-(instrument, timeframe)
    timeline cursor that decides whether an incoming candle is worth
    emitting. Filtering rules:

    - [candle.ts < tail_ts]   stale snapshot — drop.
    - [candle.ts > tail_ts]   new bar — emit; reset the per-ts dedup
                              set to [{candle}], advance the tail.
    - [candle.ts = tail_ts]   intra-bar refresh — emit iff this exact
                              OHLCV has not already been emitted at
                              the same ts.

    Subscribers see a stream that is monotone-or-equal in ts with no
    exact-content duplicates. Bar_closed vs Bar_updated discrimination
    (same-ts as live refresh vs strictly-newer-ts as period
    transition) is the subscriber's concern; the bus transports the
    raw observation, not a typed lifecycle event.

    {b Future direction.} This filter is the in-process prototype of a
    [Bar_series] domain aggregate keyed by (instrument, timeframe).
    The aggregate will own the same monotonicity + dedup invariants
    and act as a logical clock for the stream: every accepted bar is
    stamped with a monotonically increasing position assigned by the
    aggregate. The outbound IE carries the standard event-stream
    coordinates as metadata:

    {ul
    {- [stream_type]     — kind of stream, e.g. ["bar_series"].}
    {- [stream_id]       — the specific stream instance, e.g.
                           ["<ticker>@<venue>:<timeframe>"].}
    {- [stream_position] — the logical-clock position the aggregate
                           assigned to this bar; strictly increasing
                           within a [(stream_type, stream_id)].}}

    Subscribers' Transactional Inbox keys idempotency off
    [(stream_type, stream_id, stream_position)], making at-least-once
    delivery on the bus safe regardless of how the underlying
    transport retries. The in-process [Hashtbl] here is the stand-in
    until that aggregate, persistence, and outbox plumbing arrive. *)

open Core

val make :
  bus:Bus.bus ->
  instrument:Instrument.t ->
  timeframe:Timeframe.t ->
  candle:Candle.t ->
  unit
(** [make ~bus] returns a closure ready to be called per inbound
    candle. The closure holds the per-key timeline state for the
    lifetime of the returned function — typically the lifetime of
    the broker factory instance. *)

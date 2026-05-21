(** REST-pagination utility for historical bar fetching.

    Brokers cap the per-call bar count returned by their REST [bars]
    endpoint (Finam: 5000, BCS: smaller). To cover an arbitrary date
    range you have to walk the window backwards in chunks until the
    oldest requested timestamp is reached or the broker stops making
    progress.

    Consumer scope: the offline ML tooling under [bin/]
    ([train_logistic], [export_training_data]). The runtime composition
    in [bin/main.ml] doesn't paginate — it consumes bars through the
    WS bridge or, for backtest, from the synthetic generator.

    Type surface depends only on [Core.Candle.t] and stdlib [int64];
    {b broker-agnostic} by construction. The [fetch] callback hides
    which broker is being driven, so the same paginator powers both
    Finam and BCS exports. *)

open Core

val paginate_bars :
  fetch:(from_ts:int64 -> to_ts:int64 -> Candle.t list) ->
  from_ts:int64 ->
  to_ts:int64 ->
  Candle.t list
(** Walk a [fetch] callback backwards from [to_ts] until [from_ts]
    is covered or the broker stops making progress. Returns the
    accumulated candles in chronological order with duplicates on
    chunk boundaries de-duplicated by timestamp.

    Bounded at 200 iterations as a safety stop against broker-side
    pagination bugs that could otherwise loop indefinitely. *)

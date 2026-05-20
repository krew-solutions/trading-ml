(** Handler for inbound TRADES events: resolves each execution
    leg against this adapter's placement store, recovers the
    originating Submit's correlation_id from the command log,
    accumulates per-placement [new_total_filled], and publishes
    a {!Broker_integration_events.Order_filled_integration_event}
    for downstream EM consumption.

    [total_filled] is a per-process Hashtbl handed in by the
    surrounding factory — its lifetime tracks the adapter's, and
    sliding restarts replay from REST [get_trades] on cold
    start. Pre-warm logic doesn't live here; we just take what
    the caller hands us.

    [origin_correlation_id] is the
    {!Broker_store.Order_command_log.S.origin_correlation_id}
    closure (placement_id → correlation_id from the most recent
    Submit). A miss means the placement was never observed by
    this adapter's Submit path; we drop the event with a warn
    log rather than synthesising a correlation_id, because
    fills against unknown placements indicate a wiring problem
    upstream and must not silently produce IEs the saga can't
    correlate. *)

val handle :
  finam:Finam_broker.t ->
  origin_correlation_id:(placement_id:int -> string option) ->
  total_filled:(int, Decimal.t) Hashtbl.t ->
  publish_order_filled:
    (Broker_integration_events.Order_filled_integration_event.t -> unit) ->
  Trade.update list ->
  unit

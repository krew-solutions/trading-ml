(** Transport supervisor: holds one WS-primary + REST-fallback
    transport pair for a single inbound event stream, switching
    between them transparently on WS health transitions.

    The supervisor exists because the broker-adapter port
    ({!Broker.S}) promises that consumers see one unified event
    callback regardless of how the underlying transport delivered
    the event (WS push, REST poll, synthetic). Today's adapters
    typically run one transport; this module captures the pattern
    of running both and ensuring the consumer never notices a
    disconnect.

    {1 What the supervisor owns vs. what it doesn't}

    Owns:

    - one always-running poll fiber that ticks at
      [poll_interval] but no-ops when the WS branch is healthy.
    - the [last_ts] cursor that advances on every emitted event
      and seeds the REST [since_ts] argument.
    - the [ws_healthy] / [poll_active] flags wired into the WS
      bridge's [on_disconnect] / [on_reconnect] hooks. The
      invariant [ws_healthy ⇒ ¬poll_active] is preserved.

    Does not own:

    - the WS bridge — the caller starts the bridge under the
      same {!Eio.Switch.t} and wires its lifecycle callbacks
      (initial connect, [on_disconnect], [on_reconnect]) into
      {!ws_came_up} / {!ws_went_down} / {!ws_reconnected}.
    - the {!Stream_dedup} table — the caller supplies a
      [dedup_accept] closure (which usually binds a
      {!Stream_dedup}), so the same dedup state can be shared
      with non-supervised paths (e.g. an OHS publisher that
      observes the same stream).
    - the final consumer callback — the caller passes [emit].

    {1 State transitions}

    - {b INIT}: [poll_active=true], [ws_healthy=false]. The poll
      fiber starts polling immediately; WS comes up in parallel.
    - {b WS first connect succeeds}: caller invokes
      {!ws_came_up}; supervisor flips poll dormant.
    - {b WS lost}: bridge's [on_disconnect] fires; caller invokes
      {!ws_went_down}; the always-running poll fiber resumes
      filling the gap on its next tick.
    - {b WS reconnects}: bridge's [on_reconnect] fires; caller
      invokes {!ws_reconnected}; supervisor performs one
      synchronous catch-up poll over [(last_ts, now)], then
      flips poll dormant.

    {1 Dedup}

    Both WS and REST branches funnel events through
    [dedup_accept]. The caller is expected to bind a
    {!Stream_dedup} keyed by a discriminator that's stable across
    both transports (e.g. [placement_id] / [trade_id] for fills,
    [(instrument, timeframe)] for bars). The supervisor never
    sees duplicates twice.

    {1 Catch-up window}

    On reconnect the supervisor calls [poll_window
    ~since_ts:last_ts ~to_ts:now] once to cover the disconnect
    gap. REST endpoints with bounded windows (e.g. last-N-seconds)
    may fail to surface every event if the gap exceeds their
    horizon; callers should pick a [poll_interval] short enough
    that any missed event is also recovered by the steady-state
    poll while WS is down. *)

type 'event t

val start :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  label:string ->
  poll_interval:float ->
  ts_now:(unit -> int64) ->
  poll_window:(since_ts:int64 -> to_ts:int64 -> 'event list) ->
  ts_of_event:('event -> int64) ->
  dedup_accept:('event -> bool) ->
  emit:('event -> unit) ->
  initial_since_ts:int64 ->
  'event t
(** Spawn the poll fiber under [sw] and return the supervisor
    handle. The supervisor begins in INIT (poll active), waiting
    for the caller to wire the WS lifecycle. *)

val feed_ws : 'event t -> 'event -> unit
(** Funnel an event that arrived via the WS branch through dedup
    and emit. Callers wire this from the WS bridge's
    [on_event]-equivalent callback. *)

val ws_came_up : 'event t -> unit
(** Signal that the WS first connect just succeeded. Flips poll
    dormant. Call once from the WS bridge's initial connect
    completion. *)

val ws_went_down : 'event t -> unit
(** Signal that the WS just disconnected. Flips poll active.
    Wire from {!Websocket.Resilient.config.on_disconnect}. *)

val ws_reconnected : 'event t -> unit
(** Signal that the WS just reconnected after a drop. Performs
    one synchronous catch-up poll over [(last_ts, now)], then
    flips poll dormant. Wire from
    {!Websocket.Resilient.config.on_reconnect}. *)

val stop : 'event t -> unit
(** Halt the supervisor. The poll fiber exits on its next
    wake-up; subsequent {!feed_ws} / {!ws_came_up} /
    {!ws_went_down} / {!ws_reconnected} calls are no-ops.
    Idempotent.

    Use case: per-subscription supervisors (e.g. BCS bars,
    where one supervisor is created per [(instrument,
    timeframe)] pair) need a tear-down hook when the
    subscription is dropped. Account-wide supervisors (e.g.
    BCS execution-status) are bound to the parent switch and
    rarely need explicit stopping. *)

(** Strategy BC composition root.

    {!build} stands up the alpha-emitting engine when a strategy is
    configured: a {!Live_engine.t}, the inbound bar handler that
    feeds candles into it, the bus subscription that routes
    [broker.bar-updated] events through that handler, and the
    daemon fiber that runs the engine's pull-driven pipeline.

    When [strategy:None] is passed, [build] is a no-op except for
    the HTTP stub — no engine, no bar subscription, no fiber. *)

open Core

type t = { http_handler : Inbound_http.Route.handler }

val build :
  bus:Bus.bus ->
  sw:Eio.Switch.t ->
  strategy:Strategies.Strategy.t option ->
  strategy_id:string ->
  engine_symbol:Instrument.t ->
  t
(** Construct the Strategy runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by Strategy's inbound URI
    ([broker.bar-updated]) and outbound URI
    ([strategy.signal-detected]).

    [sw] anchors the engine fiber's lifetime; when the switch
    closes the daemon winds down.

    [strategy] is the parsed-and-built {!Strategies.Strategy.t}
    when [--strategy] is set; [None] disables the engine.

    [strategy_id] is the stable identifier echoed in every emitted
    {!Strategy_integration_events.Signal_detected_integration_event.strategy_id}
    field — typically the [name] from the strategy registry.

    [engine_symbol] is the single instrument the engine trades
    today (single-instrument MVP). *)

(** Strategy BC composition root.

    {!build} stands up the live-trading engine when a strategy is
    configured: a {!Live_engine.t}, the inbound bar handler that
    feeds candles into it, the bus subscription that routes
    [broker.bar-updated] events through that handler, and the
    daemon fiber that runs the engine's pull-driven pipeline.

    When [strategy:None] is passed, [build] is a no-op except for
    the HTTP stub — no engine, no bar subscription, no fiber.

    {b Why a factory.} Same rationale as {!Account_factory.Factory}
    and {!Portfolio_management_factory.Factory}: composition root
    knowledge of Strategy stays inside the BC. *)

open Core

type t = {
  http_handler : Inbound_http.Route.handler;
      (** Stub today; gains real routes when the engine grows a
          telemetry / control surface. *)
  on_fill_event : (Live_engine.fill_event -> unit) option;
      (** Port for delivering broker fill events into the engine's
          reservation ledger. [Some] when an engine was built,
          [None] otherwise. The composition root wires this to the
          actual fill source — today {!Paper.Paper_broker.on_fill}
          when paper mode is active; tomorrow an inbound ACL
          handler subscribed to a [broker.fill-executed] topic. *)
}

val build :
  bus:Bus.bus ->
  sw:Eio.Switch.t ->
  broker:Broker.client ->
  strategy:Strategies.Strategy.t option ->
  engine_symbol:Instrument.t ->
  t
(** Construct the Strategy runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by Strategy's inbound URI
    ([broker.bar-updated]).

    [sw] anchors the engine fiber's lifetime; when the switch
    closes the daemon winds down.

    [broker] is the upstream order-execution surface — Live_engine
    submits orders through it. The composition root supplies a
    paper-wrapped or live broker as configured.

    [strategy] is the parsed-and-built {!Strategies.Strategy.t}
    when [--strategy] is set; [None] disables the engine. CLI
    parsing of [--strategy] / [--param] is the composition root's
    job, not the factory's.

    [engine_symbol] is the single instrument the engine trades
    today (single-instrument MVP). Bar events for any other
    instrument are filtered out at the inbound handler. *)

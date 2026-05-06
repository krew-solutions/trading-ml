(** Broker BC composition root.

    {!build} stands up the entire Broker-side runtime against a
    pre-constructed {!Bus.bus}: outbound producers, the optional
    {!Paper.Paper_broker} decorator, the WS-bridge for live brokers
    (Finam / BCS), the [Submit_order_command] dispatcher, and the
    HTTP route handler. It exposes a small surface to the
    composition root: the resolved [Broker.client], the optional
    [Paper.Paper_broker.t] for cross-BC fill wiring, a
    [market_price] port for Account, an optional [ws_setup] for
    {!Server.Http.run}, and the HTTP route handler.

    {b Why a factory.} See {!Account_factory.Factory} for the
    rationale — same pattern, same future-distributed migration
    story. Broker's factory is the largest of the four because it
    owns the WS bridges, the Paper decorator, and the only
    outbound-event publisher in the system. *)

open Core

(** Tagged variant for the live REST handle the WS bridge needs.
    [Synthetic] means «no live data source»: the factory yields no
    [ws_setup]. *)
type rest = Finam of Finam.Rest.t | Bcs of Bcs.Rest.t | Synthetic

type t = {
  client : Broker.client;
      (** Either [source_client] directly, or that wrapped in
          [Paper.Paper_broker.as_broker] when [paper_mode] is true. *)
  paper_broker : Paper.Paper_broker.t option;
      (** [Some] when [paper_mode] is true, [None] otherwise. The
          composition root needs this to wire Paper's [on_fill]
          callback to {!Strategy_factory.Factory.t.on_fill_event}. *)
  market_price : instrument:Instrument.t -> Decimal.t;
      (** Closure over [Broker.bars client]; latest mark for the
          requested instrument. Account factory consumes this for
          cash-impact reference at reservation time. *)
  ws_setup : (sw:Eio.Switch.t -> Server.Http.live_setup) option;
      (** WS-bridge factory for live brokers. [None] for synthetic
          (no WS upstream). Passed to {!Server.Http.run} as [?setup]. *)
  http_handler : Inbound_http.Route.handler;
      (** Broker-side HTTP routes (orders list/get/cancel,
          /api/exchanges). See {!Broker_inbound_http.Http}. *)
}

val build :
  bus:Bus.bus ->
  env:Eio_unix.Stdenv.base ->
  source_client:Broker.client ->
  rest:rest ->
  paper_mode:bool ->
  t
(** Construct the Broker runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by Broker's outbound URIs
    ([broker.order-{accepted,rejected,unreachable}],
    [broker.bar-updated]).

    [env] is used inside the WS bridges (clock, network, fiber
    spawning).

    [source_client] is the raw broker client opened by
    {!Broker_boot}. The factory may wrap it in
    {!Paper.Paper_broker.as_broker} depending on [paper_mode].

    [rest] supplies the live REST handle the WS bridge needs;
    [Synthetic] disables [ws_setup].

    [paper_mode] controls Paper-decoration: when [true], every
    order goes through {!Paper.Paper_broker} for in-memory
    simulation against the live bar stream. *)

(** Broker BC composition root.

    {!build} stands up the entire Broker-side runtime against a
    pre-constructed {!Bus.bus}: outbound producers, the WS-bridge
    for live brokers (Finam / BCS), the [Submit_order_command]
    dispatcher, and the HTTP route handler. It exposes a small
    surface to the composition root: the resolved [Broker.client],
    a [market_price] port for Account, an optional [ws_setup] for
    {!Server.Http.run}, and the HTTP route handler.

    {b Why a factory.} See {!Account_factory.Factory} for the
    rationale — same pattern, same future-distributed migration
    story. Broker's factory is the largest of the four because it
    owns the WS bridges and the only outbound bar-event publisher
    in the system.

    {b Paper mode.} When [paper_mode = true], the paper_broker BC
    handles the saga's [submit-order-command] traffic via its own
    bus subscription. Broker's submit-order subscriber is therefore
    gated off in paper mode to avoid double-handling. Bars produced
    by the live WS bridge (or by the backtest driver) continue to
    flow through this BC's [broker.bar-updated] publisher; the
    paper_broker BC's inbound ACL consumes them. *)

open Core

(** Tagged variant for the live REST handle the WS bridge needs.
    [Synthetic] means «no live data source»: the factory yields no
    [ws_setup]. *)
type rest = Finam of Finam.Rest.t | Bcs of Bcs.Rest.t | Synthetic

type t = {
  client : Broker.client;
      (** [source_client]. In paper mode order routing is handled
          by the paper_broker BC; this field still exposes the data
          source for HTTP queries (bars, accounts, etc.). *)
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
  now:(unit -> int64) ->
  source_client:Broker.client ->
  rest:rest ->
  paper_mode:bool ->
  t
(** Construct the Broker runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by Broker's outbound URIs
    ([broker.order-{accepted,rejected,cancelled,unreachable}],
    [broker.bar-updated]).

    [env] is used inside the WS bridges (clock, network, fiber
    spawning).

    [now] is broker's injected clock — UnixClock in live mode,
    VirtualClock in backtest. Used today to stamp
    {!Order_cancelled_integration_event}'s [cancelled_ts]; future
    workflows that need wall-clock time will source it from here.

    [source_client] is the raw broker client opened by
    {!Broker_boot} — the data source.

    [rest] supplies the live REST handle the WS bridge needs;
    [Synthetic] disables [ws_setup].

    [paper_mode] gates the saga's submit-order and
    cancel-pending-order subscriptions symmetrically: when [true],
    paper_broker BC owns those channels and broker BC does not
    subscribe. *)

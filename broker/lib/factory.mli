(** Broker BC composition root.

    {!build} stands up the entire Broker-side runtime against a
    pre-constructed {!Bus.bus}: outbound producers, the WS-bridge
    for live brokers (Finam / BCS), the [Submit_order_command]
    dispatcher, and the HTTP route handler. It exposes a small
    surface to the composition root: the resolved [Broker.client],
    a [market_price] port for Account, an optional [ws_setup] for
    {!Server.Http.run}, and the HTTP route handler.

    Adapter opening (translating primitive credentials into a live
    REST + adapter handle) lives under {!Opened} so the composition
    root never needs to import Finam / BCS / Synthetic directly.

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

(** Discriminated handle for an opened broker adapter. Combines the
    abstract {!Broker.client} (used by command/query ports) with the
    concrete REST handle and adapter that the WS bridge and reconcile
    fibers reach into directly.

    Composition-root code calls one of {!Opened.open_finam} /
    {!Opened.open_bcs} / {!Opened.open_synthetic} and passes the
    result to {!build}. Internals of Finam / BCS / Synthetic stay
    inside the broker BC. *)
module Opened : sig
  type t = private
    | Finam of {
        client : Broker.client;
        rest : Finam.Rest.t;
        adapter : Finam.Finam_broker.t;
      }
    | Bcs of { client : Broker.client; rest : Bcs.Rest.t; adapter : Bcs.Bcs_broker.t }
    | Synthetic of { client : Broker.client }

  val client : t -> Broker.client
  (** Extract the abstract broker client. Used by callers that
      care only about the {!Broker.client} surface (e.g. Account's
      [market_price] port, the backtest harness). *)

  val env_prefix : string -> string
  (** [env_prefix broker_id] returns the env-var prefix for the
      named broker — ["BCS"] for ["bcs"], ["FINAM"] for everything
      else. Used by CLI tooling to resolve [_SECRET] / [_ACCOUNT_ID]
      env vars consistently across binaries. *)

  val open_finam : env:Eio_unix.Stdenv.base -> secret:string -> account_id:string -> t

  val open_bcs :
    env:Eio_unix.Stdenv.base ->
    ?secret:string ->
    ?account_id:string ->
    ?client_id:string ->
    unit ->
    t
  (** [?secret], if present, seeds the persistent file at
      [$XDG_STATE_HOME/trading/bcs-refresh-token] before reading.
      Subsequent runs read the rotated token from the file
      automatically; [BCS_SECRET] env var is the bootstrap
      fallback when the file is still empty. *)

  val open_synthetic : unit -> t
end

type t = {
  client : Broker.client;
      (** The opened adapter's abstract client. In paper mode order
          routing is handled by the paper_broker BC; this field
          still exposes the data source for HTTP queries (bars,
          accounts, etc.). *)
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
  opened:Opened.t ->
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

    [opened] is the opened broker adapter — typically constructed
    by the composition root via {!Opened.open_finam} /
    {!Opened.open_bcs} / {!Opened.open_synthetic}. Carries both the
    abstract client and the concrete REST + adapter handles needed
    for the WS bridge.

    [paper_mode] gates the saga's submit-order and
    cancel-pending-order subscriptions symmetrically: when [true],
    paper_broker BC owns those channels and broker BC does not
    subscribe. *)

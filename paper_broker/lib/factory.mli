(** paper_broker BC composition root.

    {!build} wires up the entire paper_broker-side runtime against a
    pre-constructed {!Bus.bus}: in-memory state, workflow ports,
    outbound producers, and inbound subscriptions for the command
    channel and the upstream bar feed.

    paper_broker has no HTTP surface of its own: orders enter via
    the [broker.submit-order-command] bus channel (published by the
    execution_management saga or any other client), bars enter via
    [broker.bar-updated], and outcomes (Order_accepted /
    Order_filled / Order_cancelled / Order_rejected) leave on
    [broker.order-*] channels. The {!t.http_handler} field is a
    no-op stub kept for uniformity with the other BC factories. *)

type t = { http_handler : Inbound_http.Route.handler }

val build :
  bus:Bus.bus ->
  slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.t ->
  fee_rate:Paper_broker.Fee.Values.Fee_rate.t ->
  t
(** Construct the paper_broker runtime.

    [bus] must already have an adapter registered for the
    [in-memory://] scheme used by paper_broker's outbound URIs
    ([broker.order-accepted], [broker.order-filled],
    [broker.order-cancelled], [broker.order-rejected]) and inbound
    URIs ([broker.submit-order-command],
    [broker.cancel-order-command], [broker.bar-updated]).

    [slippage_bps] / [fee_rate] are simulator configuration. Tests
    and synthetic-data backtests typically pass
    {!Paper_broker.Slippage.Values.Slippage_bps.zero} and
    {!Paper_broker.Fee.Values.Fee_rate.zero}. *)

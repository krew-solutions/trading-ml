(** Execution_management BC composition root.

    Wires up the {!Place_order_pm} Process Manager against the bus,
    holds the kill-switch and rate-limit aggregates, subscribes to
    the upstream gate / saga-feeding integration events, and exposes
    an HTTP handler for the trading host to mount. *)

type t = { http_handler : Inbound_http.Route.handler }

type config = {
  initial_equity : Decimal.t;
  max_drawdown_pct : float;
      (** Kill-switch trigger as fraction in [0,1]. [0.0] disables. *)
  rate_limit : (int * float) option;
      (** [Some (max_orders, window_seconds)] caps submission rate;
        [None] disables. *)
}

val build : bus:Bus.bus -> now:(unit -> int64) -> config:config -> t
(** [now] supplies ambient time (epoch seconds), used by the
    rate-limit gate, the kill-switch [occurred_at] stamp, and the
    [Trade_submission_blocked] event timestamp. See ADR 0013. *)

(** pre_trade_risk BC composition root. Allocates per-book Risk_view
    aggregates, builds command-dispatch ports, subscribes to the
    upstream integration-event topics, and exposes the HTTP handler
    for the trading host to mount. *)

type t = { http_handler : Inbound_http.Route.handler }

val build : bus:Bus.bus -> initial_equity:Decimal.t -> t
(** [initial_equity] feeds {!Pre_trade_risk.Risk_limits.default}. The
    same defaults that the original [Engine.Risk.default_limits]
    produced. *)

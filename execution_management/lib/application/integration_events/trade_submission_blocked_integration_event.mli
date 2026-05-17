(** Integration event: execution_management blocked a submission
    before it reached the venue.

    Telemetry-only. The {!Order_process_manager} saga does not consume this
    event — instances that hit a gate never start, and there is no
    Reserve/Submit chain to compensate. The IE exists so SSE / audit
    consumers can show the user why an approved trade intent never
    became an order.

    The wire shape is generated from
    [shared/contracts/execution_management/integration_events/trade_submission_blocked_integration_event.atd]
    via atdgen. *)

include module type of Trade_submission_blocked_integration_event_t

include module type of Trade_submission_blocked_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

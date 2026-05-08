(** Integration event: execution_management blocked a submission
    before it reached the venue.

    Telemetry-only. The {!Place_order_pm} saga does not consume this
    event — instances that hit a gate never start, and there is no
    Reserve/Submit chain to compensate. The IE exists so SSE / audit
    consumers can show the user why an approved trade intent never
    became an order. *)

type t = {
  correlation_id : string;
  reason : string;  (** ["kill_switch"] | ["rate_limit"]. *)
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]

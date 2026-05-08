(** Integration event: the kill switch tripped — submissions are
    halted until an operator resets it. Telemetry-only consumers
    (SSE, audit, alerting). *)

type t = {
  peak_equity : string;  (** Decimal string. *)
  current_equity : string;  (** Decimal string. *)
  drawdown : float;  (** Fraction in [0, 1]. *)
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]

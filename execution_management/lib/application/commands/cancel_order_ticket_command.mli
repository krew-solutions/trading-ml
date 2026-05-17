(** Command: operator-initiated cancel of an in-flight ticket. *)

type t = {
  ticket_id : int;
  reason : string;
      (** ["operator" | "kill_switch" | "risk_limit_breach"]
          (matches {!Values.Cancel_reason.t}). *)
}

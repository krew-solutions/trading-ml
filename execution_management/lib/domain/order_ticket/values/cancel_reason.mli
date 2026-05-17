(** Why a ticket transitioned to cancelling/cancelled.

    [Operator] — explicit operator-issued cancel; the typical
    UI / supervisor case.
    [Kill_switch] — global kill-switch tripped; in-flight tickets
    abort. (Today the kill-switch acts at submission time only;
    this constructor reserves space for the runtime-cancel
    extension when wired up.)
    [Risk_limit_breach] — pre-trade risk discovered post-hoc that
    the position now exceeds a limit; abort the in-flight ticket. *)

type t = Operator | Kill_switch | Risk_limit_breach

val to_string : t -> string

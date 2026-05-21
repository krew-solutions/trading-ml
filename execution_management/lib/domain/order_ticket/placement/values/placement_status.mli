(** Lifecycle status of a single Placement inside an OrderTicket.

    Transitions are linear from the [Pending] entry state to one
    of the four terminal states (Filled, Rejected, Unreachable,
    Cancelled). [Working] is the intermediate "in market"
    state — entered on broker acknowledgement, exited on the
    first terminal event.

    [Filled] is reached when cumulative fill quantity equals the
    placement's requested quantity. Partial fills keep the
    placement in [Working]. *)

type t = Pending | Working | Filled | Rejected | Unreachable | Cancelled

val is_terminal : t -> bool
(*@ r = is_terminal s
    ensures r <-> (s = Filled \/ s = Rejected \/ s = Unreachable \/ s = Cancelled) *)

val to_string : t -> string

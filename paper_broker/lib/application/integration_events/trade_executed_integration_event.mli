(** Integration event: one trade was executed against a working
    order in paper_broker's book. Published on
    [in-memory://broker.trade-executed] after a successful
    [apply_bar_command_workflow] match. One order may produce
    multiple trades across consecutive bars (partial fills under
    a participation cap, IS-style slicing); each emits its
    own [Trade_executed] IE.

    Carries the actuals of the trade only (quantity, price, fee);
    reconciling trades into a running total is the consuming
    aggregate's job (the OrderTicket in execution_management),
    not the paper venue's. *)

include module type of Trade_executed_integration_event_t
include module type of Trade_executed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Paper_broker.Order.Events.Trade_executed.t

val of_domain : correlation_id:string -> domain -> t

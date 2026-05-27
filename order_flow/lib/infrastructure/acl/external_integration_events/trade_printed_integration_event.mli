(** Mirror of the broker BC's outbound public-tape integration event.
    Wire shape regenerated from the producer's .atd contract
    (shared/contracts/broker/integration_events/trade_printed_integration_event.atd),
    duplicated here per ADR 0001 — no code-level dependency on broker. *)

include module type of Trade_printed_integration_event_t
include module type of Trade_printed_integration_event_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

(** Hexagonal port: persistence of {!Order_ticket.t} aggregates,
    keyed by {!Ticket_id.t}.

    The store is the consistency boundary for command-workflow
    transactions — each command loads the current aggregate
    snapshot, applies a domain operation, saves the result, and
    publishes the emitted events. (Persistent backends with
    transactional semantics land in a follow-up; PR4b ships an
    in-memory adapter that mirrors {!Workflow_engine.In_memory_store}.)

    Concurrency: callers are responsible for serialising
    operations per-ticket (the engine that drives the workflow
    holds its own mutex on the ticket key). The store's
    [get] / [put] do not themselves coordinate concurrent writers
    on the same key. *)

module type S = sig
  type t

  val get :
    t ->
    Execution_management.Order_ticket.Values.Ticket_id.t ->
    Execution_management.Order_ticket.t option

  val put : t -> Execution_management.Order_ticket.t -> unit

  val all_open : t -> Execution_management.Order_ticket.t list
  (** All non-terminal tickets, for scheduler-driven tick fan-out
      and operator queries. Order is unspecified. *)

  val active_count : t -> int
  (** Number of non-terminal tickets — diagnostic. *)
end

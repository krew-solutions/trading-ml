(** Process-correlation log: maps each accepted command on an
    Order aggregate to the [correlation_id] of the saga that
    issued it.

    Why a separate store, not an envelope wrapping the aggregate:
    one aggregate participates in multiple processes over its
    lifecycle (Submit, Cancel, …), each with its own
    [correlation_id]. There is no "the correlation_id of this
    Order" — there are as many as there were processes that
    touched it. See *Process correlation is not aggregate state*
    in [docs/architecture/hexagonal-architecture.md].

    Until the project adopts a proper event log (in which
    correlation lives as event metadata), this explicit store is
    the substitute. Consumers most commonly query
    {!origin_correlation_id} to recover the originating-Submit
    correlation when emitting an outbound event that has no
    correlation context of its own (e.g. a [Trade_executed] event
    produced by per-bar matching, since the bar carries no
    correlation_id).

    Aggregate identity is the surrogate {!Paper_broker.Order.t.id}
    (string). For paper_broker, [placement_id] is the natural
    identifier and could equally be used — the implementation can
    key by either; this port abstracts that choice. *)

module type S = sig
  type t

  val record_submit : t -> aggregate_id:string -> correlation_id:string -> unit
  (** Idempotent: re-recording the same [aggregate_id] under [`Submit]
      replaces any prior entry. *)

  val record_cancel : t -> aggregate_id:string -> correlation_id:string -> unit

  val origin_correlation_id : t -> aggregate_id:string -> string option
  (** The [correlation_id] recorded by the most recent
      {!record_submit} for this aggregate. [None] if no Submit was
      logged (e.g. unknown aggregate, or a corrupted log).

      Downstream events ([Trade_executed]) that lack a direct
      command-in-scope use this to recover the originating saga. *)

  val cancel_correlation_id : t -> aggregate_id:string -> string option
  (** Symmetric reader for {!record_cancel}. [None] if the
      aggregate was never cancelled. Today this is exposed for
      symmetry / future compensation audit; the current workflows
      do not consume it. *)
end

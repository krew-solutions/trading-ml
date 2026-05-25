(** Process-correlation log: maps each accepted command on a
    saga-placed order to the [correlation_id] of the saga that
    issued it.

    Why a separate store, not envelope-on-the-aggregate: a single
    placement participates in multiple processes over its
    lifecycle (Submit, Cancel, future Reconcile / Refresh) — each
    with its own [correlation_id]. There is no "the
    correlation_id of this order" — there are as many as there
    were processes that touched it.

    Why now, given broker doesn't (yet) emit fill events outside
    command-in-scope: parity with paper_broker's
    {!Paper_broker_store.Order_command_log.S}, plus the
    audit/compensation hook future fill-from-WS events will need
    in order to stamp the originating saga on the outbound IE.

    The natural key is [placement_id : int]. Broker BC has no
    aggregate of its own (the venue owns the order) — the saga
    key is the only stable cross-process handle. Native venue
    identities ([client_order_id], server-side ids) live
    privately inside each ACL adapter and never reach this log.

    Until the project adopts a proper event log (in which
    correlation lives as event metadata), this explicit store is
    the substitute. *)

module type S = sig
  type t

  val record_submit : t -> placement_id:int -> correlation_id:string -> unit
  (** Idempotent: re-recording the same [placement_id] under
      [`Submit] replaces any prior entry. *)

  val record_cancel : t -> placement_id:int -> correlation_id:string -> unit

  val origin_correlation_id : t -> placement_id:int -> string option
  (** The [correlation_id] recorded by the most recent
      {!record_submit} for this placement. [None] if no Submit
      was logged (unknown placement, corrupted log, or the
      placement was rejected pre-Submit). Downstream events
      generated outside command-in-scope (Trade_executed
      from WS) use this to recover the originating saga. *)

  val cancel_correlation_id : t -> placement_id:int -> string option
  (** Symmetric reader for {!record_cancel}. [None] if the
      placement was never cancelled. Exposed for symmetry /
      future compensation audit; current workflows do not
      consume it. *)
end

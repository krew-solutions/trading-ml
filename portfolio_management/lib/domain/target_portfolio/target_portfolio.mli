(** Aggregate root: the desired state of one book. Indexed by
    [Book_id.t]. The aggregate enforces:

    - per-instrument single-valuedness: at most one entry per
      instrument, so a target proposal that mentions an instrument
      already present overwrites it (does not duplicate);
    - zero-target prunes: an entry with [target_qty = 0] is removed
      from [positions], so [target_for] yields [Decimal.zero] for an
      absent instrument by the same path as for a never-set one;
    - book consistency: [apply_proposal] rejects any proposal whose
      [book_id] differs from the aggregate's book, and any leg in
      the proposal whose [book_id] differs from the proposal's;
    - idempotence: applying the same proposal twice yields the same
      state and an event whose [changed] list is empty on the second
      call.

    Pure value type; no I/O. *)

(** Re-exports of peer subdirs. The aggregate's [.ml] collapses the
    [target_portfolio/] namespace per dune's qualified-mode rule, so
    peer subdirectories are visible outside only through these
    explicit publications. *)

module Events : module type of Events

type t

val empty : Common.Book_id.t -> t
val book_id : t -> Common.Book_id.t

val positions : t -> Common.Target_position.t list
(** Snapshot view, in deterministic instrument-compare order. *)

val target_for : t -> Core.Instrument.t -> Decimal.t
(** Signed target quantity for [instrument]; [Decimal.zero] if absent. *)

(** Reasons why the aggregate refuses to apply a proposal.
    Business-rule errors, not programming errors. *)
type apply_error =
  | Book_id_mismatch of {
      aggregate_book : Common.Book_id.t;
      proposal_book : Common.Book_id.t;
    }
  | Position_book_id_mismatch of {
      proposal_book : Common.Book_id.t;
      position_instrument : Core.Instrument.t;
      position_book : Common.Book_id.t;
    }

val apply_proposal :
  t -> Common.Target_proposal.t -> (t * Events.Target_set.t, apply_error) result
(** Apply a target proposal. The aggregate replaces all matching
    instrument entries with the values from the proposal; instruments
    in [positions] but absent from the proposal are LEFT UNTOUCHED.
    The semantic is "merge / overwrite by instrument", not "replace
    the whole target portfolio".

    Idempotent: a second call with the same proposal produces the
    same state and a [Target_set] event whose [changed] list is
    empty. *)

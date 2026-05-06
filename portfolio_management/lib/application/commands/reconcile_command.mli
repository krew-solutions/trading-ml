(** Inbound command to PM: "compute the trade list bringing
    [book_id]'s actual_portfolio to its target_portfolio and announce
    it via the {!Trade_intents_planned_integration_event.t}."

    Idempotent — called whenever target or actual changes (or
    explicitly by a tick / scheduler). [computed_at] supplies the
    timestamp the produced domain event will carry. *)

type t = { book_id : string; computed_at : string  (** ISO-8601 *) } [@@deriving yojson]
